# Windowsill

Winter for your Mac desktop. Snow piles up on top of your windows and the Dock and flies off when you
drag a window. At Christmas you can grow trees, decorate them, roll snowmen onto your windows and get
visits from Santa, a gift train and a Yeti who steals snowmen. A painted winter wallpaper and the snow
follow your local sunrise and sunset.

It lives in the menu bar, has no Dock icon and collects nothing. Its only network request is a daily look
at this repository's latest release, so the panel can tell you when a new version is out; Settings >
**Check for new versions** turns it off.
The wallpaper and the Christmas characters and decorations are paintings bundled inside the app; the code animates them (gallops, walk cycles, swaying baubles,
turning wheels). Nothing is downloaded at run time.

## Install

1. Download `Windowsill.dmg` from the repository's **Releases** page (between releases: the
   `Windowsill-app` artifact of a successful run under **Actions**, which holds the dmg and a zip).
2. Open the dmg, drag Windowsill to Applications, and open it. A snowflake appears in the menu bar; click
   it for the panel. If a full menu bar or the notch hides the snowflake, open Windowsill again from
   Applications and the same panel opens in a window.
3. A build made without the signing secrets is not notarized, and macOS blocks its first open: click
   **Done**, then System Settings > Privacy & Security > **Open Anyway**.

[docs/DISTRIBUTION.md](docs/DISTRIBUTION.md) covers that in full, plus signing and notarizing, cutting a
release, checking a download, and uninstalling.

Requires macOS 26 Tahoe or later; runs natively on Apple silicon and Intel.

## Features

| Tab | What it does |
|---|---|
| Weather | Snow, with amount, wind and opacity sliders and gusts and lulls of its own. It piles up on window tops, the Dock and the bottom of the screen, following each window's rounded corners. Nudge a window and its snow sways; fling it and the snow flies off; close it and the snow drops in clumps that burst where they land. Settled snow can melt. "Fall behind windows" keeps the snow out of the way of your work. |
| Christmas | Grow up to three trees and decorate them with baubles, lights, candy canes and a star. Roll snowmen onto windows; they ride along when you move the window. Presents fall from Santa's sleigh; click one to open it. The gift train stops at your first tree to deliver. The Yeti walks up to a snowman and carries it off unless you click him. Visitors come by themselves every 6 to 15 minutes, or call them now. |
| Wallpapers | A painted winter scene at day, evening and night. "Follow the time of day" switches with your local sunrise and sunset, and the snow and decorations are lit to match. |
| Settings | Open at login, show on every display, keep going over full-screen apps, show in screenshots and screen sharing, power status. |

Effects pause by themselves in full-screen apps (unless you ask otherwise), while the display sleeps and
while the screen is locked, and run at half density and 30 fps on battery, in Low Power Mode or when the
Mac runs hot. The weather stays out of screenshots and screen sharing unless you turn that on. Opened
straight from the disk image, Windowsill offers to move itself to Applications.

A few of these ideas (melting, falling behind windows, staying out of screen sharing, clumps from a
closed window, drops under windows) came from looking at [Snowhush](https://github.com/mbezruchko/Snowhush);
they are written afresh here, and no Snowhush code is used.

## Roadmap

Built, but not shipped yet: more weather (leaves, cherry blossom, rain, starfall, fireflies) and five more
painted wallpapers (Rain, Stars, Fireflies, Autumn, Spring). The code and paintings are in the repository;
`Effect.shipping` and `Theme.shipping` in `Sources/Windowsill/State.swift` decide what the panel offers,
and `scripts/build-app.sh` bundles only the shipped paintings.

## Build it yourself

```bash
bash scripts/build-app.sh dist
dist/Windowsill.app/Contents/MacOS/Windowsill --selfcheck
```

The paintings live in `Resources/Wallpapers/`; `python scripts/import-paintings.py <folder>` rebuilds them
from the source PNGs. The characters live in `Resources/Sprites/`; `python scripts/import-sprites.py <folder>`
cuts them from the transparent sprite sheets `windowsill-sprites-<sheet>.png` (kept in `art-src/`).
CI records its screenshots and videos with a separate build, `DEMO=1 bash scripts/build-app.sh dist-demo`, whose
`--demo <effect|christmas|panel>` runs a scripted demo with its own settings and windows. Release builds leave the
demo out entirely.

## License

All rights reserved; see [LICENSE](LICENSE). You are welcome to read the source and to build and run it
for yourself.
