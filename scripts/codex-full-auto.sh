#!/usr/bin/env bash
set -euo pipefail

if ! command -v codex >/dev/null 2>&1; then
  echo "Codex CLI not found on PATH." >&2
  echo "Install or open Codex, then retry from the repo root." >&2
  exit 127
fi

TASK="${*:-}"

if [[ -z "$TASK" ]]; then
  cat <<'USAGE'
Usage:
  npm run codex:auto -- "Implement the requested change and run targeted checks"

This runs Codex with VZT's full-auto project profile:
  codex exec --sandbox workspace-write

Hard safety gates still apply by protocol:
  no secrets, force pushes, production deploys, DB migrations, or writes outside the workspace.
USAGE
  exit 2
fi

codex exec --sandbox workspace-write "$TASK" < /dev/null
