# Firefox profile fixtures (audit F10)

These synthetic files reproduce on-disk profile layouts without personal browser
data. `tests/run-sandbox.sh` copies `home/` into its throwaway home before taking
the pristine snapshot. No Firefox process, package or network access is needed.

| Layout | Discovery | Existing state |
|---|---|---|
| Native `native.default` | `profiles.ini`, `Default=1` | Custom `user.js` and `chrome/userChrome.css` to merge/replace and restore |
| Native `native.default-release` | Second profile in version 2 `profiles.ini` | Browser-owned `prefs.js`; `user.js` and `chrome/` must be created and removed |
| Flatpak `flatpak profile.default-release` | Relative path with spaces, no `Default=1` | Custom `user.js`, no `chrome/` |
| Snap `snap.default` | No INI; `*.default` fallback | Existing `chrome/keep.css`, no `user.js` or `userChrome.css` |
| Snap `snap.default-release` | No INI; `*.default-release` fallback | Browser-owned `prefs.js`, no `user.js` or `chrome/` |

The Snap root also has a non-profile directory that must remain untouched.

The dry-run test requires planned CSS and preference writes for all five
profiles while leaving the home and manifest untouched. The roundtrip test
checks exact CSS, exact JavaScript preference blocks, preserved unrelated files,
and identical output after a second install. Uninstall must restore the entire
home to its pristine contents, including pre-existing files and directories,
and remove all newly created files and empty directories.

This tests filesystem installation and rollback, not Firefox's rendering or
compatibility with a live browser version. It does not claim coverage of absolute
`IsRelative=0` paths or every possible profile registry format.
