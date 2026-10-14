# Credits

sway98 installs and wires up other people's work. Nothing here would exist
without them, and most of the look is theirs, not ours.

## Theme, icons, cursors, fonts

| Project | Author | License | What sway98 uses |
|---|---|---|---|
| [Chicago95](https://github.com/grassmunk/Chicago95) | grassmunk and contributors | GPL-3.0+/MIT | GTK 2/3/4 themes, icon theme, Win95 cursor themes, Plymouth and SDDM themes, Qt colour scheme (`Extras/Chicago95_qt.conf`), LibreOffice icon set, shell and terminal extras |
| [int10h.org](https://int10h.org/oldschool-pc-fonts/) — VileR | VileR | CC BY-SA 4.0 | `LessPerfectDOSVGA.ttf`, `MorePerfectDOSVGA.ttf`, shipped in Chicago95 under `Fonts/vga_font` |
| Cronyx | Cronyx | public domain / X11 style | Cyrillic bitmap fonts in `Fonts/bitmap/cronyx-cyrillic` |

Chicago95 is fetched at install time and pinned to commit
`e89583c9a0fbc5022d099fbe6f12132a756027a8`; no upstream file is redistributed from
this repository.

## Desktop components

| Project | License | Used for |
|---|---|---|
| [Sway](https://swaywm.org/) | MIT | window manager the whole theme is built around |
| [Waybar](https://github.com/Alexays/Waybar) | MIT | the Win98 taskbar |
| [wofi](https://hg.sr.ht/~scoopta/wofi) | GPL-3.0 | application launcher styling |
| [mako](https://github.com/emersion/mako) | MIT | notification popups |
| [kitty](https://sw.kovidgoyal.net/kitty/) | GPL-3.0 | terminal, VGA palette |
| [fcitx5](https://github.com/fcitx/fcitx5) | LGPL-2.1+ | input method panel theme |
| [qt5ct](https://github.com/trialuser02/qt5ct) / [qt6ct](https://github.com/trialuser02/qt6ct) | BSD-2-Clause | optional Qt colour scheme delivery |
| [Kvantum](https://github.com/tsujan/Kvantum) | GPL-3.0 | optional Qt style engine (not required) |
| [libcanberra](https://0pointer.de/lennart/projects/libcanberra/) | LGPL-2.1+ | plays sound theme events |

## Fonts referenced by the theme

| Font | License |
|---|---|
| Liberation Sans (fontconfig default in the theme) | SIL Open Font License 1.1 |
| Noto Sans CJK (CJK fallback) | SIL Open Font License 1.1 |
| JetBrains Mono Nerd Font (Waybar icons) | SIL Open Font License 1.1, patched by [nerd-fonts](https://github.com/ryanoasis/nerd-fonts) |

## Microsoft assets (not distributed)

The `sounds` module downloads Windows 98 system sounds from the Internet Archive:

| Source | What | Rights |
|---|---|---|
| [Microsoft: Windows 98 System sounds (1998)](https://archive.org/details/Microsoft_Windows-98-System-Sounds) | the Win98 sound scheme | Microsoft copyright; downloaded only at the user's request and stored on their machine |

The same applies to anything else Windows-related you might add yourself: boot
logos, wallpapers, original MS Sans Serif. The project ships addresses and
checksums, not files.

## Documentation and research

| Source | License | Used for |
|---|---|---|
| [Arch Wiki](https://wiki.archlinux.org/) | GNU FDL 1.3+ | Sway, Plymouth, Qt/GTK integration notes quoted in `docs/` |
| [Flathub](https://flathub.org/apps/org.gtk.Gtk3theme.Chicago95) | — | published `org.gtk.Gtk3theme.Chicago95` runtime for Flatpak apps |

## Firefox

If you extend `modules/firefox/files/userChrome.css`, credit
[MrOtherGuy/firefox-csshacks](https://github.com/MrOtherGuy/firefox-csshacks)
(MIT) when you borrow from it — and keep in mind that Mozilla's internal DOM is
not a stable API.
