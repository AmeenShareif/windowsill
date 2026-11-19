# Windowsill

Weather for your Mac desktop. Snow piles up on top of your windows and the Dock and flies off when you
drag a window; leaves, cherry blossom, rain, starfall and fireflies each behave their own way. At
Christmas you can grow trees, decorate them, roll snowmen onto your windows and get visits from Santa,
a gift train and a Yeti who steals snowmen. Six painted wallpapers follow the time of day.

It lives in the menu bar, has no Dock icon and collects nothing. Its only network request is a daily look
at this repository's latest release, so the panel can tell you when a new version is out; Settings >
**Check for new versions** turns it off.
The wallpapers, the Christmas characters and decorations, and the falling leaves and petals are
paintings bundled inside the app; the code animates them (gallops, walk cycles, swaying baubles,
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
| Weather | Snow, Leaves, Starfall, Rain, Sakura, Fireflies; amount, wind and opacity sliders, with gusts and lulls of their own. Snow and leaves pile up on window tops, the Dock and the bottom of the screen, following each window's rounded corners. Fling a window and its snow flies off; close it and the snow drops in clumps that burst where they land. Settled snow can melt. Brush leaves or petals with the pointer to scatter them. Fireflies gather where the pointer rests. Rain gathers in drops under each window, splashes and brings lightning. "Fall behind windows" keeps the weather out of the way of your work. |
| Christmas | Grow up to three trees and decorate them with baubles, lights, candy canes and a star. Roll snowmen onto windows; they ride along when you move the window. Presents fall from Santa's sleigh; click one to open it. The gift train stops at your first tree to deliver. The Yeti walks up to a snowman and carries it off unless you click him. Visitors come by themselves every 6 to 15 minutes, or call them now. |
| Wallpapers | Winter, Rain, Stars, Fireflies, Autumn and Spring painted scenes, each at day, evening and night. "Follow the time of day" switches at sunrise and nightfall. |
| Settings | Open at login, show on every display, keep going over full-screen apps, show in screenshots and screen sharing, power status. |

Effects pause by themselves in full-screen apps (unless you ask otherwise), while the display sleeps and
while the screen is locked, and run at half density and 30 fps on battery, in Low Power Mode or when the
Mac runs hot. The weather stays out of screenshots and screen sharing unless you turn that on. Opened
straight from the disk image, Windowsill offers to move itself to Applications.

A few of these ideas (melting, falling behind windows, staying out of screen sharing, clumps from a
closed window, drops under windows) came from looking at [Snowhush](https://github.com/mbezruchko/Snowhush);
they are written afresh here, and no Snowhush code is used.

## Build it yourself

```bash
bash scripts/build-app.sh dist
dist/Windowsill.app/Contents/MacOS/Windowsill --selfcheck
```

The paintings live in `Resources/Wallpapers/`; `python scripts/import-paintings.py <folder>` rebuilds them
from the source PNGs. The characters live in `Resources/Sprites/`; `python scripts/import-sprites.py <folder>`
cuts them from the transparent sprite sheets `windowsill-sprites-<sheet>.png` (kept in `art-src/`).
`--demo <effect|christmas|panel>`
runs the scripted demo CI screenshots; it uses its own settings and never touches yours.

## License

All rights reserved; see [LICENSE](LICENSE). You are welcome to read the source and to build and run it
for yourself.
