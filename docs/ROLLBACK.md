# Rolling back

herdr-extensions is an installer, not a deployed service: there is no server, database or
migration. "Rolling back" means undoing what `install` wrote on a machine, or going back to an
earlier release.

## Undo an install

```bash
herdr-extensions uninstall           # removes the plugin and the managed keybinding block
herdr-extensions uninstall --purge   # also removes the editor configs it wrote
```

`uninstall` restores your `config.toml` byte-for-byte, because keybindings live between managed
markers and everything outside them is never touched. Run `herdr-extensions doctor` afterwards to
confirm nothing is left behind.

## Go back to a previous release

Releases are tagged and published through the Homebrew formula in `Formula/herdr-extensions.rb`.

1. Check out the previous tag's formula (`git checkout vX.Y.Z -- Formula/herdr-extensions.rb`),
   or point `url` and `sha256` at that tag's tarball.
2. Reinstall from it: `brew reinstall --formula ./Formula/herdr-extensions.rb`.
3. Re-run `herdr-extensions install` so the rendered plugin manifest and scripts match the
   older version, then `herdr-extensions doctor`.

To pull a bad release for everyone, revert the formula bump on `main` so the checksum points back
at the last good tarball. Do not rewrite or delete a published tag.

## Database migrations

None. This repo has no database.
