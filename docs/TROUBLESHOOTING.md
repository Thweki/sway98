# Symptom → cause → fix

## Nothing changed at all after installing

**Cause:** most applications read their appearance once, at startup.
**Fix:** reload the compositor and restart the applications.

```
swaymsg reload
```

GTK applications, kitty, Firefox and Qt applications all need to be restarted
(Firefox: *quit completely*, `Ctrl+Shift+Q`). Flatpak applications need the
`flatpak` module and a restart. Qt applications need a fresh login so that
`QT_QPA_PLATFORMTHEME=gtk3` reaches them — check with:

```
systemctl --user show-environment | grep QT_QPA_PLATFORMTHEME
```

## Window titles are still dark/blue from my old theme

**Cause:** your own sway config sets `client.*` colours **after** the sway98
include, or sway98's include is not the last one.
**Fix:** make sure this line is the last line of `~/.config/sway/config`:

```
include ~/.config/sway/conf.d/sway98.conf
```

Sway applies later values over earlier ones, so the include has to come last.

## The taskbar has boxes instead of icons

**Cause:** no Nerd Font installed; Waybar's icon glyphs are private-use
codepoints.
**Fix:** `sudo pacman -S ttf-jetbrains-mono-nerd`, or edit
`~/.config/waybar/config` and replace the glyphs with words.

## Firefox looks unchanged

1. The CSS needs `toolkit.legacyUserProfileCustomizations.stylesheets`, which the
   module adds in a marker block in `user.js` — check the profile really is the
   one you are using (`about:support` → *Profile Folder`).
2. Firefox has to be *fully* quit, not reloaded.
3. If it broke after a Firefox update, that is the expected failure mode of
   userChrome.css. Remove just that part: `./uninstall.sh --only firefox`.

Flatpak Firefox lives under `~/.var/app/org.mozilla.firefox/.mozilla/firefox`,
Snap Firefox under `~/snap/firefox/common/.mozilla/firefox`; the installer looks
in all three places.

## GTK applications (GTK 4 / GNOME-styled ones) ignore the theme

libadwaita applications do not read `gtk-theme-name` at all — that is by design
upstream, not a bug in sway98. Options: use GTK3 builds where available, accept
Adwaita for those apps, or install a libadwaita-aware recolouring project
separately.

## Qt applications are still Adwaita/Breeze

* `QT_QPA_PLATFORMTHEME=gtk3` must be in the environment of the *application*.
  Under a systemd-managed session `~/.config/environment.d/90-sway98-qt.conf`
  covers it; if you start sway from a TTY, let the installer add the export to
  `~/.profile` (or add it yourself) and log in again.
* `sudo pacman -S gtk3 qt5-base qt6-base` — the plugin needs the GTK3 platform
  theme that ships with Qt itself.

## Text in the input method panel is wrong or the panel is invisible

`~/.config/fcitx5/conf/classicui.conf` must contain `Theme=win98`, and fcitx5 has
to be restarted: `fcitx5 -r -d --replace`. If your input method works in GTK apps
but not in X11 ones, the missing piece is in
`~/.config/sway/conf.d/sway98.d/fcitx5.conf` — the
`dbus-update-activation-environment` line. Remove the duplicate if your config
already does this.

## The sounds module downloaded nothing

Expected if you answered "no" to the download prompt. To get the files later:

```
./modules/sounds/fetch-ms-sounds.sh          # verifies sha1 of every file
./install.sh --only sounds
```

If the download fails with a TLS error, you hit the archive.org redirect problem:
do not use `https://archive.org/download/...`, fetch through the metadata API as
`lib/fetch.sh` does.

## I want my old configuration back

```
./uninstall.sh --dry-run     # see exactly what would be reverted
./uninstall.sh               # do it
```

Backups live in `~/.local/state/sway98/backups/<timestamp>/`, the manifest
history in `~/.local/state/sway98/manifest/history/`. Nothing is deleted on
uninstall, so a wrong rollback can be re-applied by hand.

## The installer refuses to run

* "run sway98 as your normal user, not as root" — it installs into `$HOME`, so
  root would theme root's home, not yours.
* "unknown module" — check the spelling against `./install.sh --list`.
* A module that needs a download needs `curl`; `theme` needs `git`.

## System-level modules (planned)

`sddm` and `plymouth` are not implemented yet. When they are, they will require
`--system` and the README will document the recovery path (a TTY plus
`arch-chroot` from a live medium) before anything is written.
