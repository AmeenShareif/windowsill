# Windowsill design (2026-11-18)

## Intent
A Mac app with every feature KoiArt shows (desktop weather that piles on windows, Christmas decorations
and visitors, a gift train, painted wallpapers), built from source the owner can read instead of
installing an app they do not trust. Original name and original art.

## Decisions (owner's)
- Build on GitHub Actions: a private repo, a macOS runner compiles, self-checks, renders previews and
  produces `Windowsill.zip`.
- The friends gift train does **not** send anything to other people: no networking at all. The train
  delivers presents to your own trees.

## Approaches considered
1. **Native Swift: SpriteKit overlay + SwiftUI menu bar panel** (chosen). One transparent click-through
   panel per screen above normal windows; `CGWindowListCopyWindowInfo` at 30 Hz gives window tops to land
   on. Small, fast, no dependencies, reviewable.
2. Electron or Tauri with a WebGL overlay: larger, needs a JS toolchain, and transparent click-through
   windows over other apps are awkward there.
3. A screensaver or wallpaper-only app: cannot pile snow on live windows, which is the point.

## How it works
- `WindowTracker` snapshots on-screen windows (front to back), the Dock and the floor of each screen.
- `WeatherScene` (SpriteKit) moves particles, lands them on the highest uncovered surface below, and keeps
  a heightmap `Pile` per surface. Moving a window throws its pile with the window's velocity.
- The overlay ignores the mouse except over a decoration or visitor (checked at 30 Hz), so clicks pass
  through to the apps underneath.
- Decorations persist in UserDefaults; snowmen re-attach to windows by position after a relaunch.
- Wallpapers are painted anime-style scenes (made in ChatGPT, one chat per theme so the three lights
  share a composition), bundled as `Resources/Wallpapers/<theme>-<day|evening|night>.jpg`, copied to
  Application Support and set with `NSWorkspace.setDesktopImageURL`. The owner rejected the first,
  code-drawn landscapes as "cartoon"; paintings replaced them. Re-import with
  `python scripts/import-paintings.py <folder of windowsill-<theme>-<light>.png>`.

## Panel look
- The header is a live miniature of the chosen weather over a window ledge (TimelineView + Canvas,
  still under Reduce Motion); the wordmark is New York serif, everything else is system text.
- Each effect owns one tint (snow 6FB2EA, leaves D9822B, starfall D9AE3F, rain 5F86B0, sakura E57AA6,
  fireflies 8DB83A) and a sky pair; controls take the tint through `.tint`, nothing else is coloured.
- Spacing is 4/8/12/16. Only the on/off toggle floats: Liquid Glass on macOS 26 (built only by a
  Swift 6.2+ compiler), `.ultraThinMaterial` before that.
- State stays `ObservableObject`: the overlay engine listens to `objectWillChange` through Combine.

## Calls made by the builder
- Time of day uses fixed clock hours, not real sunrise (that needs location access).
- Settings live in UserDefaults; no accounts, no sync.
- Distribution is an ad-hoc signed zip; notarization needs a paid Apple developer account.
- No custom app icon yet (menu bar apps rarely show one).
