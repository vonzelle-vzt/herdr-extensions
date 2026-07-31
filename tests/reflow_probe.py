#!/usr/bin/env python3
"""Reflow probe -- runs one panel attached to a REAL pty, starts it at one width, resizes the pty
and confirms the panel redraws at the new width via SIGWINCH.

A plain pipe has no controlling terminal at all, so neither ioctl(TIOCSWINSZ) nor the kernel's
automatic SIGWINCH-on-resize exist without a pty. This allocates one with pty.openpty(), starts
the panel at 100 columns, waits (bounded) for its first render, resizes the pty's window size to
50 columns -- which is what actually makes the kernel deliver SIGWINCH to the foreground process
group, the same mechanism a real terminal emulator uses -- and waits (bounded) for a second render
that reflects the new width.

HARD BOUNDED throughout: a SIGALRM backstop plus explicit read deadlines, and the child is always
killed in a `finally` so a panel that never redraws cannot hang this probe or the gate that runs
it.

Usage: reflow_probe.py <panel-path> [env KEY=VALUE ...]
Prints RESULT:OK or RESULT:FAIL:<reason> as the last line of stdout. The full transcript is
printed to stderr for debugging a failure.
"""
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

RULE_RE = re.compile(r"-{20,}")


class Timeout(Exception):
    pass


def _alarm(_sig, _frame):
    raise Timeout("probe exceeded its overall deadline")


def set_winsize(fd, cols, rows=24):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))


def read_until(master_fd, pid, predicate, deadline, buf=b""):
    """Read from master_fd, APPENDING to `buf` (a continuous transcript, never reset between
    phases -- resetting it would let the tail end of the FIRST render's still-in-flight output get
    miscounted as evidence of a second one), until predicate(buf) is true or the deadline passes.
    Returns (buf, matched: bool). Never blocks past `deadline`."""
    while time.time() < deadline:
        try:
            r, _, _ = _select_ready(master_fd, 0.1)
        except OSError:
            break
        if not r:
            # Also bail out early if the child already exited -- no more output is coming.
            try:
                exited_pid, _ = os.waitpid(pid, os.WNOHANG)
                if exited_pid == pid:
                    break
            except ChildProcessError:
                break
            continue
        try:
            chunk = os.read(master_fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        if predicate(buf):
            return buf, True
    return buf, predicate(buf)


def _select_ready(fd, timeout):
    return select.select([fd], [], [], timeout)


def main():
    if len(sys.argv) < 2:
        print("RESULT:FAIL:usage: reflow_probe.py <panel-path> [KEY=VALUE ...]")
        return 1
    panel_path = sys.argv[1]
    extra_env = dict(kv.split("=", 1) for kv in sys.argv[2:])
    # Some panels (search) prompt for a line of input BEFORE they ever reach their redraw loop.
    # REFLOW_PROBE_SEND_ENTER, if present, is stripped out of the env passed to the child and
    # instead tells THIS probe to type a bare Enter into the pty right after start, so that panel
    # can get past its prompt and reach the width-aware redraw this test is actually about.
    send_enter = extra_env.pop("REFLOW_PROBE_SEND_ENTER", None) == "1"
    # review has no "press any key" state at all (it stays interactive for notes), so it needs its
    # own idle marker -- and that marker must be something that cannot appear INCIDENTALLY inside
    # whatever content the panel is displaying. Using the shared "Press any key to close" against
    # review's own diff view is exactly how this went wrong once already: reviewing a diff of THIS
    # repository's other panels means that literal string appears in the diffed content itself,
    # so phase 1 matched on partial mid-render output and resized while review was still writing.
    idle_marker = extra_env.pop("REFLOW_PROBE_IDLE_MARKER", "Press any key to close")
    # Per-phase deadline. Default 8s is plenty for every panel except markdown: glow queries the
    # terminal's background colour (OSC 10/11) to pick chroma colours, and this synthetic pty has
    # nothing on the other end to answer that query, so glow blocks on its OWN ~15s internal
    # timeout before giving up and rendering anyway. Answering the query programmatically was
    # tried and made things WORSE: the fake response bytes, written to the pty master, arrive as
    # literal keyboard INPUT to whatever reads next -- which, once the render finishes, is the
    # panel's "press any key" read, so the injected escape byte was consumed as a keypress and
    # exited the panel before the second render could ever happen. Waiting out glow's own timeout
    # is slower but correct; markdown gets a longer deadline via REFLOW_PROBE_PHASE_DEADLINE.
    try:
        phase_deadline = float(extra_env.pop("REFLOW_PROBE_PHASE_DEADLINE", "8"))
    except ValueError:
        phase_deadline = 8.0

    signal.signal(signal.SIGALRM, _alarm)
    signal.alarm(int(phase_deadline * 2) + 20)  # overall backstop -- nothing here should take longer

    master_fd, slave_fd = pty.openpty()
    set_winsize(slave_fd, 100)

    env = dict(os.environ)
    env.update(extra_env)
    env.setdefault("TERM", "xterm-256color")

    pid = os.fork()
    if pid == 0:
        # Child: become session leader so the slave becomes its controlling tty, then exec.
        os.close(master_fd)
        os.setsid()
        fcntl.ioctl(slave_fd, termios.TIOCSCTTY, 0)
        os.dup2(slave_fd, 0)
        os.dup2(slave_fd, 1)
        os.dup2(slave_fd, 2)
        if slave_fd > 2:
            os.close(slave_fd)
        try:
            os.execvpe("/bin/bash", ["/bin/bash", panel_path], env)
        except Exception:
            os._exit(127)
    os.close(slave_fd)

    if send_enter:
        try:
            os.write(master_fd, b"\n")
        except OSError:
            pass

    result = "RESULT:FAIL:unknown"
    buf = b""
    try:
        # Phase 1: wait for the render to fully finish (not just start) -- resizing WHILE the
        # panel is still mid-redraw is the realistic failure mode this probe used to trip over
        # itself: bash's `trap '' SIG` truly DISCARDS a signal that arrives while masked, it does
        # not queue it for once the trap is re-armed, so a SIGWINCH landing inside that window is
        # simply lost. Waiting for the idle marker matches how a real resize actually happens too:
        # a user resizes while the panel is sitting there, not mid-paint.
        buf, matched = read_until(
            master_fd, pid, lambda b: idle_marker.encode() in b,
            time.time() + phase_deadline,
        )
        if not matched:
            result = "RESULT:FAIL:no initial render captured within the deadline"
            return 1
        if RULE_RE.search(buf.decode(errors="replace")) is None:
            result = "RESULT:FAIL:panel rendered but drew no width rule at all"
            return 1

        # Phase 2: resize the pty. This is what makes the kernel deliver SIGWINCH to the
        # foreground process group -- the same mechanism a real terminal resize uses, not a
        # synthetic signal we invented for the test.
        set_winsize(master_fd, 50)
        try:
            os.killpg(os.getpgid(pid), signal.SIGWINCH)
        except (ProcessLookupError, PermissionError, OSError):
            pass

        # Phase 3: wait for a SECOND full render (a second idle marker) whose rule is exactly 50
        # columns wide -- proof the panel actually re-read the width, not just that it redrew.
        def saw_new_width(b):
            if b.count(idle_marker.encode()) < 2:
                return False
            rules = RULE_RE.findall(b.decode(errors="replace"))
            return len(rules) >= 2 and any(len(r) == 50 for r in rules)

        buf, matched = read_until(master_fd, pid, saw_new_width, time.time() + phase_deadline, buf=buf)
        text = buf.decode(errors="replace")
        rules = RULE_RE.findall(text)
        if len(rules) < 2:
            result = "RESULT:FAIL:only %d render(s) captured -- SIGWINCH did not trigger a redraw" % len(rules)
        elif not any(len(r) == 50 for r in rules):
            result = (
                "RESULT:FAIL:redrew %d time(s) but no 50-column rule found (widths seen: %s) -- "
                "panel redrew without picking up the new size" % (len(rules), sorted({len(r) for r in rules}))
            )
        else:
            result = "RESULT:OK"
        return 0 if result == "RESULT:OK" else 1
    except Timeout:
        result = "RESULT:FAIL:probe hit its overall SIGALRM backstop -- panel likely hung"
        return 1
    finally:
        signal.alarm(0)
        try:
            os.killpg(os.getpgid(pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            pass
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        try:
            os.close(master_fd)
        except OSError:
            pass
        sys.stderr.write(buf.decode(errors="replace"))
        print(result)


if __name__ == "__main__":
    sys.exit(main())
