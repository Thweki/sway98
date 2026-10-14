# Screenshots

The three images in this directory are embedded in the top-level READMEs.

| File | Content |
|---|---|
| `desktop.png` | the whole session: Win98 taskbar, DOS-coloured kitty, Chicago95 icons in Thunar |
| `notification.png` | the same session with a mako popup in Win98 dialog style |
| `launcher.png` | wofi with the Win98 skin |

## How they are generated

```
tests/screenshots.sh              # rewrite all three
SWAY98_SHOT_RES=1920x1200 tests/screenshots.sh
```

The script starts a **throwaway headless sway** with a private runtime dir, a
private D-Bus session and a private config home that is populated from this
repository's own module assets — so the pictures show what `sway98` installs
rather than whatever the developer's machine happens to be configured with.
Nothing appears on the desktop of the person running it.

Two details worth knowing before changing the script:

* `swaymsg` must be given `SWAYSOCK` explicitly. With only `XDG_RUNTIME_DIR` set
  it can resolve to the *real* session, which is why the script refuses to
  continue unless the session it reached reports a `HEADLESS-*` output.
* The Wi-Fi SSID is masked in the rendered Waybar config (the shipped config
  shows it). Keep that in mind before publishing images from a real machine: a
  screenshot of a themed desktop is also a screenshot of tab titles, file names
  and network names.

## What does not belong here

* **Windows 98 sounds, wallpapers and fonts are Microsoft copyright.** Do not
  commit the original boot logo, the classic wallpaper or the startup sound; the
  teal `#008080` desktop is a colour and is safe.
* Personal data: browser tabs, terminal history, notification contents, session
  URLs, subscription links.
