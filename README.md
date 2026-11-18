# Windowsill

Weather for your Mac desktop. Snow piles up on top of your windows and the Dock and flies off when you
drag a window; leaves, cherry blossom, rain, starfall and fireflies each behave their own way. At
Christmas you can grow trees, decorate them, roll snowmen onto your windows and get visits from Santa,
a gift train and a Yeti who steals snowmen. Six painted wallpapers follow the time of day.

It lives in the menu bar, has no Dock icon, makes **no network connections** and collects nothing.
The weather and Christmas art is drawn in code; the wallpapers are paintings bundled inside the app,
so nothing is downloaded at run time.

## Install

1. Download `Windowsill-app` from the latest successful run under **Actions**, and unzip it twice
   (the artifact zip holds `Windowsill.zip`, which holds `Windowsill.app`).
2. Move `Windowsill.app` to `/Applications`.
3. The build is signed ad hoc, not notarized, so macOS quarantines it. Clear that once in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Windowsill.app
   ```

4. Open it. A snowflake appears in the menu bar.

Requires macOS 14 Sonoma or later; runs natively on Apple silicon and Intel.

## Features

| Tab | What it does |
|---|---|
| Weather | Snow, Leaves, Starfall, Rain, Sakura, Fireflies; amount and wind sliders. Snow and leaves pile up on window tops, the Dock and the bottom of the screen. Fling a window and its snow flies off. Brush leaves or petals with the pointer to scatter them. Fireflies gather where the pointer rests. Rain splashes and brings lightning. |
| Christmas | Grow up to three trees and decorate them with baubles, lights, candy canes and a star. Roll snowmen onto windows; they ride along when you move the window. Presents fall from Santa's sleigh; click one to open it. The gift train stops at your first tree to deliver. The Yeti walks up to a snowman and carries it off unless you click him. Visitors come by themselves every 6 to 15 minutes, or call them now. |
| Wallpapers | Winter, Rain, Stars, Fireflies, Autumn and Spring painted scenes, each at day, evening and night. "Follow the time of day" switches at sunrise and nightfall. |
| Settings | Open at login, show on every display, battery status. |

Effects pause by themselves in full-screen apps and while the display sleeps, and run at half density
and 30 fps on battery or in Low Power Mode.

## Build it yourself

```bash
bash scripts/build-app.sh dist
dist/Windowsill.app/Contents/MacOS/Windowsill --selfcheck
```

The paintings live in `Resources/Wallpapers/`; `python scripts/import-paintings.py <folder>` rebuilds them
from the source PNGs. `--demo <effect|christmas|panel>`
runs the scripted demo CI screenshots; it uses its own settings and never touches yours.
