import CoreGraphics
import Foundation
import ImageIO
import SpriteKit

/// `Windowsill --selfcheck`: offline, headless checks of the logic that does not need a screen.
enum SelfCheck {
    static func run() -> Never {
        var failures: [String] = []
        var count = 0
        func check(_ ok: Bool, _ what: @autoclosure () -> String) {
            count += 1
            if !ok { failures.append(what()) }
        }

        // Snow piles: capped, never steeper than one grain over the slope limit, low at the ends, full in the middle.
        var pile = Pile(width: 400, cap: 14)
        var rng = SplitMix64(seed: 42)
        for _ in 0..<20_000 { pile.add(at: .random(in: 0..<400, using: &rng), amount: 0.5) }
        let h = pile.heights
        check(h.allSatisfy { $0 >= 0 && $0 <= pile.cap }, "pile exceeds its cap: max \(h.max() ?? 0)")
        let steepest = zip(h, h.dropFirst()).map { abs($0 - $1) }.max() ?? 0
        check(steepest <= pile.maxStep + 0.5 + 1e-6, "pile slope \(steepest) > \(pile.maxStep + 0.5)")
        check(h[0] <= pile.maxStep / 2 + 0.5 && h[h.count - 1] <= pile.maxStep / 2 + 0.5,
              "pile ends too high: \(h[0]), \(h[h.count - 1])")
        check(h[h.count / 2] == pile.cap, "pile middle never filled: \(h[h.count / 2])")
        check(!pile.add(at: 200, amount: 0.5), "a pile full in the middle accepted another grain there")
        pile.clear()
        check(pile.isEmpty, "cleared pile not empty")
        // Heavy flakes (the demo's boosted snow) must still spread into a drift, not a picket fence.
        for _ in 0..<300 { pile.add(at: .random(in: 0..<400, using: &rng), amount: 6) }
        let heavy = pile.heights
        let heavySteep = zip(heavy, heavy.dropFirst()).map { abs($0 - $1) }.max() ?? 0
        check(heavySteep <= pile.maxStep * 1.5 + 1e-6, "heavy flakes left a step of \(heavySteep)")
        pile.clear()
        var narrow = Pile(width: 2, cap: 5)
        check(narrow.heights.count == 1, "a 2 pt surface should be one bucket")
        narrow.add(at: 1, amount: 0.5)
        check(narrow.total == 0.5, "first grain on a narrow ledge should stick")

        // A pile rides its window: a jolt sheds a share of it, a resize drops only what lay past the moved edge.
        func ledge() -> Pile {
            var p = Pile(width: 40, cap: 14)
            for x in stride(from: CGFloat(2), to: 40, by: 4) { p.add(at: x, amount: 1) }
            return p
        }
        var jolted = ledge()
        check(abs(jolted.total - 10) < 1e-6, "test ledge should hold 10, holds \(jolted.total)")
        let shaken = jolted.shed(0.25)
        check(abs(shaken.reduce(0, +) - 2.5) < 1e-6 && abs(jolted.total - 7.5) < 1e-6, "shed 25% of 10 gave \(shaken.reduce(0, +))")
        check(jolted.shed(0).isEmpty, "a zero jolt shed snow")
        let wide = CGRect(x: 0, y: 0, width: 40, height: 10)
        var right = ledge()
        let offRight = right.refit(from: wide, to: CGRect(x: 0, y: 0, width: 20, height: 10))
        check(right.heights.count == 5 && abs(right.total - 5) < 1e-6 && offRight.count == 5 && offRight.allSatisfy { $0.x > 20 },
              "narrowing from the right kept \(right.total), dropped x \(offRight.map(\.x))")
        var left = ledge()
        let offLeft = left.refit(from: wide, to: CGRect(x: 20, y: 0, width: 20, height: 10))
        check(left.heights.count == 5 && abs(left.total - 5) < 1e-6 && offLeft.allSatisfy { $0.x < 20 },
              "narrowing from the left kept \(left.total), dropped x \(offLeft.map(\.x))")
        var grown = ledge()
        check(grown.refit(from: wide, to: CGRect(x: 0, y: 0, width: 60, height: 10)).isEmpty && abs(grown.total - 10) < 1e-6,
              "widening a window dropped snow")
        var moved = ledge()
        check(moved.refit(from: wide, to: wide.offsetBy(dx: 300, dy: 50)).isEmpty && abs(moved.total - 10) < 1e-6,
              "moving a window without resizing it refit its snow")

        // Frames come unevenly on a busy Mac, so now and then one sees no move, then the next two.
        // That is still a steady drag: snow and presents ride it. A flick that stops dead
        // throws nearly everything and knocks a present off.
        func ride(_ moved: [CGFloat]) -> (shed: CGFloat, jolt: CGFloat) {
            var m = Motion(), keep: CGFloat = 1, top: CGFloat = 0
            for (i, d) in moved.enumerated() {
                let j = m.add(moved: CGVector(dx: d, dy: 0), at: Double(i) / 60).jolt
                top = max(top, j)
                keep *= 1 - Motion.shake(j, dt: 1.0 / 60)
            }
            return (1 - keep, top)
        }
        let n = 120
        let src = (0...n).map { i -> CGFloat in let k = CGFloat(i) / CGFloat(n); return 600 * k * k * (3 - 2 * k) }
        let seen = (0...n + 20).map { i in src[min(n, max(0, i - (i % 4 == 1 ? 1 : 0)))] }
        let uneven = ride(zip(seen, seen.dropFirst()).map { $1 - $0 })
        check(uneven.shed < 0.02 && uneven.jolt < 1000, "an unevenly sampled drag shed \(uneven.shed), jolt \(uneven.jolt)")
        let stop = ride(Array(repeating: CGFloat(25), count: 30) + Array(repeating: CGFloat(0), count: 30))
        check(stop.shed > 0.8 && stop.jolt > 1000, "a dead stop from 1500 pt/s shed only \(stop.shed), jolt \(stop.jolt)")
        // What rides a window is drawn ahead of it while it moves, but not past where it stopped, and
        // never the way it was going once it turns back.
        func leads(_ moved: [CGFloat]) -> [CGFloat] {
            var m = Motion()
            return moved.enumerated().map { i, d in
                _ = m.add(moved: CGVector(dx: d, dy: 0), at: Double(i) / 60)
                return m.ahead(1.0 / 30).dx
            }
        }
        let dragLead = leads(zip(src, src.dropFirst()).map { $1 - $0 })
        check(!dragLead[10..<(n - 10)].contains(0), "a drag read once a frame lost its lead mid-drag")
        let slowLead = leads(Array(repeating: CGFloat(25), count: 30) + [2, 0, 0])
        check(slowLead[30...].allSatisfy { $0 < 10 }, "a window slowing to a crawl kept its lead: \(slowLead[29...])")
        let stopLead = leads(Array(repeating: CGFloat(25), count: 30) + Array(repeating: CGFloat(0), count: 4))
        check(stopLead[29] > 40 && stopLead[30...].allSatisfy { $0 == 0 }, "a dead stop kept leading: \(stopLead[29...])")
        let turnLead = leads([25, 25, 25, 25, -5, -25])
        check(turnLead[4] == 0 && turnLead[5] <= 0, "a window turning back led the old way: \(turnLead)")
        // Snow on a window that sets off at 300 pt/s leans back, springs past upright, leans forward when it
        // stops dead, and settles within a second of the stop, never leaning past its reach.
        var sway = Sway(), leans: [CGFloat] = [], settled: Int?
        for i in 0..<200 {
            let moving = sway.step(window: CGVector(dx: i < 30 ? 300 : 0, dy: 0), dt: 1.0 / 60)
            leans.append(sway.offset.dx)
            if i >= 30, !moving, settled == nil { settled = i }
        }
        let early = leans[..<30], late = leans[30...]
        check(early.min()! < -4 && early.max()! > 0.5 && late.max()! > 4 && leans.allSatisfy { abs($0) <= Sway.reach.dx }
              && (settled ?? .max) < 90, "snow sway: \(early.min()!)...\(early.max()!), then \(late.max()!), settled at \(settled ?? -1)")
        // A slight move (100 pt/s) shows, and drops nothing: Engine.spill starts past a 7 pt lean.
        var nudge = Sway(), most: CGFloat = 0
        for i in 0..<120 {
            _ = nudge.step(window: CGVector(dx: i < 24 ? 100 : 0, dy: 0), dt: 1.0 / 60)
            most = max(most, abs(nudge.offset.dx))
        }
        check(most > 2.5 && most < 7, "a 100 pt/s nudge leaned \(most) pt: too little to see, or enough to spill")

        // Melting: a deep pile thins faster than a shallow one, nothing goes below zero, and a full
        // pile left alone is gone within five minutes.
        var thaw = Pile(width: 400, cap: 14)
        for _ in 0..<20_000 { thaw.add(at: .random(in: 0..<400, using: &rng), amount: 0.5) }
        let m = thaw.heights.count / 2, full = thaw.heights[m]
        thaw.melt(60)
        check(full == 14 && abs(thaw.heights[m] - 5) < 1e-6, "a full bucket (\(full)) after a minute of melt: \(thaw.heights[m])")
        for _ in 0..<240 { thaw.melt(1) }
        check(thaw.isEmpty && thaw.heights.allSatisfy { $0 == 0 }, "a full pile was not gone in five minutes: \(thaw.heights)")

        // A window's rounded corner: snow at the very end sits a radius lower, none past the curve.
        check(Pile.cornerDrop(at: 0, width: 100, radius: 10) == 10 && Pile.cornerDrop(at: 100, width: 100, radius: 10) == 10,
              "corner drop at the ends is not the radius")
        check(Pile.cornerDrop(at: 10, width: 100, radius: 10) == 0 && Pile.cornerDrop(at: 50, width: 100, radius: 10) == 0,
              "the top edge past the corner should be flat")
        let mid = Pile.cornerDrop(at: 3, width: 100, radius: 10)
        check(mid > 0 && mid < 10 && abs(mid - Pile.cornerDrop(at: 97, width: 100, radius: 10)) < 1e-9, "corner drop at 3 pt: \(mid)")
        check(Pile.cornerDrop(at: 0, width: 100, radius: 0) == 0, "a square surface has no corner drop")

        // Rolling a snowman: a ball takes all but `keep` of the snow it rolls over. A plan's two runs
        // gather at least what each ball needs, and there is no plan without snow or room.
        var drift = Pile(width: 600, cap: 14)
        for _ in 0..<6_000 { drift.add(at: .random(in: 0..<600, using: &rng), amount: 0.5) }
        let need = (bottom: CGFloat(600), top: CGFloat(300))
        func plan(_ p: Pile, blocked: @escaping (CGFloat) -> Bool) -> (stand: CGFloat, bottom: CGFloat, top: CGFloat)? {
            p.snowmanPlan(need: need, gap: 40, footprint: 30, keep: 0.15, blocked: blocked)
        }
        func gather(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            stride(from: min(a, b), through: max(a, b), by: Pile.bucket).reduce(0) { $0 + drift.height(at: $1) * 0.85 * Pile.bucket }
        }
        if let p = plan(drift, blocked: { _ in false }) {
            let side: CGFloat = p.top > p.stand ? 1 : -1
            check(gather(p.bottom, p.stand) >= need.bottom - 1e-6 && gather(p.top, p.stand + side * 40) >= need.top - 1e-6
                  && (p.bottom - p.stand) * side <= 0, "a snowman plan that gathers too little: \(p)")
        } else {
            check(false, "no snowman plan on a deep drift")
        }
        check(plan(drift, blocked: { _ in true }) == nil, "a snowman planned where every x is blocked")
        check(plan(Pile(width: 600, cap: 14), blocked: { _ in false }) == nil, "a snowman planned with no snow")
        var dug = drift
        let depth = dug.height(at: 300), got = dug.take(at: 300, keep: 0.15)
        check(depth > 0 && abs(got - depth * 0.85) < 1e-9 && abs(dug.height(at: 300) - depth * 0.15) < 1e-9,
              "taking from \(depth) pt of snow got \(got), left \(dug.height(at: 300))")

        // Two snowmen set down 10 pt apart shuffle until they stand clear, evenly about where they were;
        // one standing on something else is left alone.
        var row: [CGFloat] = [100, 110, 105]
        for _ in 0..<200 {
            let d = shoves(row, halves: [30, 30, 30], limit: 2) { a, b in a < 2 && b < 2 }
            row = zip(row, d).map { $0 + $1 }
        }
        check(row[1] - row[0] >= 59.5 && abs(row[0] + row[1] - 210) < 1e-9 && row[2] == 105, "shuffled apart to \(row)")
        check(shoves([0, 70], halves: [30, 30], limit: 2) { _, _ in true } == [0, 0], "things standing clear were moved")
        // A snowman that lands just right of a tree's trunk steps out to the right; the tree stays put.
        var byTree: [CGFloat] = [500, 510]
        for _ in 0..<200 {
            let d = shoves(byTree, halves: [70, 30], fixed: [0], limit: 2) { _, _ in true }
            byTree = zip(byTree, d).map { $0 + $1 }
        }
        check(byTree[0] == 500 && byTree[1] >= 599.5, "a snowman left standing in a tree at \(byTree)")

        // Running from the disk image or a translocated copy needs a move; an installed copy does not.
        for path in ["/Volumes/Windowsill/Windowsill.app",
                     "/private/var/folders/x/T/AppTranslocation/1F2E/d/Windowsill.app"] {
            check(Install.needsMove(path), "\(path) should be offered a move")
        }
        for path in ["/Applications/Windowsill.app", "/Users/a/Applications/Windowsill.app", "/Users/a/Downloads/Windowsill.app"] {
            check(!Install.needsMove(path), "\(path) should not be offered a move")
        }

        // Coordinates.
        let flipped = Geo.cocoa(fromQuartz: CGRect(x: 10, y: 20, width: 100, height: 50), primaryHeight: 900)
        check(flipped == CGRect(x: 10, y: 830, width: 100, height: 50), "quartz to cocoa flip gave \(flipped)")
        let front = [CGRect(x: 0, y: 0, width: 50, height: 50), CGRect(x: 100, y: 100, width: 10, height: 10)]
        check(Geo.covered(CGPoint(x: 105, y: 105), by: front), "point inside a front window not covered")
        check(!Geo.covered(CGPoint(x: 75, y: 75), by: front), "point between windows reported covered")

        // A window down to the floor must not take the floor away: what falls lands behind it.
        var snap = Snapshot()
        let zoomed = CGRect(x: 0, y: 80, width: 400, height: 500)
        snap.windows = [WinInfo(id: 7, frame: zoomed)]
        snap.surfaces = [Surface(key: 7, rect: zoomed, order: 0, cap: 14, isGround: false),
                         Surface(key: Surface.groundKey(0), rect: CGRect(x: 0, y: 70, width: 800, height: 10),
                                 order: 1, cap: 22, isGround: true)]
        check(snap.support(x: 200, y: 300, excluding: 7)?.key == Surface.groundKey(0), "a window reaching the floor hid the floor")
        check(snap.support(x: 200, y: 700)?.key == 7, "something above a window should land on it")
        // Just under the menu bar: a present fits on the window, a snowman does not and lands below.
        snap.surfaces[0].headroom = 50
        check(snap.support(x: 200, y: 700, height: 30)?.key == 7, "a present should fit under the menu bar")
        check(snap.support(x: 200, y: 700, height: 96)?.key == Surface.groundKey(0), "a snowman stood where the menu bar cuts its head off")
        // A Dock along the bottom hides the floor, probed just above its top as landings are, and only there.
        let floor = snap.surfaces[1]
        check(!snap.isCovered(CGPoint(x: 600, y: floor.top + 1), behind: floor), "the floor was hidden with no Dock")
        snap.dock = CGRect(x: 0, y: 0, width: 800, height: floor.top)
        check(snap.isCovered(CGPoint(x: 600, y: floor.top + 1), behind: floor), "snow can pile on the floor beside the Dock")
        check(!snap.isCovered(CGPoint(x: 600, y: floor.top + 40), behind: floor), "the Dock hid the floor far above it")
        // A moving window is drawn ahead by its lead: its surface goes with it, the floor stays put, and
        // what lies behind its new place is hidden.
        let led = snap.led(by: [7: CGVector(dx: 30, dy: 0)])
        check(led.window(7)?.frame.minX == 30 && led.surfaces[0].rect.minX == 30, "a led window's surface stayed behind")
        check(led.surfaces[1].rect == floor.rect, "the floor moved with a window")
        let past = CGPoint(x: 415, y: floor.top + 40)
        check(!snap.isCovered(past, behind: floor) && led.isCovered(past, behind: floor), "the floor showed where a led window now is")
        var flung = Motion()
        _ = flung.add(moved: .zero, at: 0)
        _ = flung.add(moved: CGVector(dx: 20, dy: 0), at: 1.0 / 60)
        check(abs(flung.ahead(2.0 / 60).dx - 40) < 0.01, "a window at 20 pt a frame should lead by 40 pt over two frames")

        // Update offers: number by number, a missing part is 0, and a pre-release is never offered.
        for (tag, mine, want) in [("1.0.1", "1.0", true), ("1.10.0", "1.9.9", true), ("1.0", "1.0.0", false),
                                  ("1.0.0", "1.0.1", false), ("2.0.0-beta", "1.0", false), ("1..0", "0.9", false)] {
            check(Updates.isNewer(tag, than: mine) == want, "\(tag) newer than \(mine) should be \(want)")
        }

        // The sun: sunrise and sunset in New York at both solstices within 3 minutes of the published times, none
        // in Tromso at either, the noon sun's height, the time of day it gives, and the zone table's estimate.
        func local(_ s: String, _ zone: String) -> Date? {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: zone)
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.date(from: s)
        }
        let ny = "America/New_York"
        for (day, rise, set) in [("2026-06-21", "05:25", "20:31"), ("2026-12-21", "07:17", "16:32")] {
            guard let noon = local("\(day) 12:00", ny), let r = local("\(day) \(rise)", ny), let s = local("\(day) \(set)", ny),
                  let got = Sun.riseSet(around: noon, lat: 40.7128, lon: -74.006) else {
                check(false, "no sunrise in New York on \(day)"); continue
            }
            check(abs(got.rise.timeIntervalSince(r)) < 180 && abs(got.set.timeIntervalSince(s)) < 180,
                  "New York \(day): sunrise \(got.rise), sunset \(got.set), want \(rise) and \(set) local")
        }
        for day in ["2026-06-21", "2026-12-21"] {
            if let noon = local("\(day) 12:00", "Europe/Oslo") {
                check(Sun.riseSet(around: noon, lat: 69.65, lon: 18.96) == nil, "Tromso had a sunrise and sunset on \(day)")
            }
        }
        if let noon = local("2026-06-21 13:00", ny), let late = local("2026-06-21 23:00", ny),
           let dusk = local("2026-06-21 21:00", ny), let early = local("2026-06-21 08:00", ny) {
            let high = Sun.position(at: noon, lat: 40.7128, lon: -74.006).elevation
            check(abs(high - 72.7) < 0.5, "New York's midsummer noon sun at \(high) degrees, want 72.7")
            for (t, want) in [(noon, TimeOfDay.midday), (late, .night), (dusk, .dusk), (early, .morning)] {
                let p = Sun.position(at: t, lat: 40.7128, lon: -74.006)
                let got = TimeOfDay.of(elevation: p.elevation, hourAngle: p.hourAngle)
                check(got == want, "New York at \(t): \(got), want \(want)")
            }
        }
        let est = Sun.estimate(TimeZone(identifier: ny) ?? .current)
        check(abs(est.lat - 40.7) < 0.2 && abs(est.lon + 74.0) < 0.2, "New York's zone estimated at \(est.lat), \(est.lon)")
        let nyc = Sun.coordinates("+404251-0740023"), sydney = Sun.coordinates("-3352+15113")
        check(abs((nyc?.lat ?? 0) - 40.714) < 0.001 && abs((nyc?.lon ?? 0) + 74.006) < 0.001
              && abs((sydney?.lat ?? 0) + 33.867) < 0.001 && abs((sydney?.lon ?? 0) - 151.217) < 0.001,
              "zone.tab coordinates misread: \(String(describing: nyc)), \(String(describing: sydney))")
        let dark = Sun.tint(elevation: -20), bright = Sun.tint(elevation: 40), low = Sun.tint(elevation: 0)
        check(bright.r == 1 && bright.g == 1 && bright.b == 1 && dark.r < 0.8 && dark.b > dark.r && low.r > low.b,
              "daylight tint: noon \(bright), night \(dark), at the horizon \(low)")
        // Decorations take the light; what glows, and particles, keep their own colours.
        let room = SKNode(), tree = SKSpriteNode(), bulb = SKSpriteNode(), core = SKSpriteNode()
        let star = SKSpriteNode(), halo = SKSpriteNode(), smoke = SKSpriteNode(), wagon = SKNode(), wheel = SKSpriteNode()
        bulb.blendMode = .add
        halo.blendMode = .add
        core.colorBlendFactor = 0.6
        bulb.addChild(core)
        star.addChild(halo)
        wagon.addChild(wheel)
        [tree, bulb, star, smoke, wagon].forEach { room.addChild($0) }
        WeatherScene.light(room, .blue, skip: [ObjectIdentifier(smoke)])
        check(tree.colorBlendFactor == 1 && wheel.colorBlendFactor == 1 && abs(core.colorBlendFactor - 0.6) < 0.001
              && bulb.colorBlendFactor == 0 && star.colorBlendFactor == 0 && smoke.colorBlendFactor == 0,
              "night light: tree \(tree.colorBlendFactor), wheel \(wheel.colorBlendFactor), bulb core \(core.colorBlendFactor), bulb \(bulb.colorBlendFactor), star \(star.colorBlendFactor), smoke \(smoke.colorBlendFactor)")

        // Tree hit-shape: ornaments may only go on the branches.
        let inside = [CGPoint(x: 0, y: 100), CGPoint(x: 60, y: 30), CGPoint(x: 0, y: 199), CGPoint(x: -30, y: 60)]
        let outside = [CGPoint(x: 0, y: 205), CGPoint(x: 70, y: 30), CGPoint(x: 0, y: 10), CGPoint(x: 40, y: 150)]
        for p in inside { check(TreeShape.contains(p), "tree should contain \(p)") }
        for p in outside { check(!TreeShape.contains(p), "tree should not contain \(p)") }

        // Seeded randomness repeats.
        var a = SplitMix64(seed: 7), b = SplitMix64(seed: 7)
        check((0..<5).map { _ in a.next() } == (0..<5).map { _ in b.next() }, "SplitMix64 is not deterministic")

        // Clock to painting: every time of day has one, and the obvious ones are right.
        check(TimeOfDay.midday.light == .day && TimeOfDay.sunset.light == .evening && TimeOfDay.night.light == .night,
              "time of day maps to the wrong painting")

        // Every shipped painting is in the bundle, decodes, is big enough for a desktop and is darker at night.
        for theme in Theme.shipping {
            var means: [Light: Double] = [:]
            for light in Light.allCases {
                guard let url = Wallpaper.url(theme, light) else {
                    check(false, "painting \(theme)-\(light) is not in the app bundle"); continue
                }
                let props = CGImageSourceCreateWithURL(url as CFURL, nil)
                    .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
                check(width >= 1500, "painting \(theme)-\(light) is only \(width) px wide")
                guard let thumb = Wallpaper.thumbnail(url, maxPixels: 64), let s = stats(thumb) else {
                    check(false, "painting \(theme)-\(light) does not decode"); continue
                }
                check(s.variance > 20, "painting \(theme)-\(light) is flat (variance \(s.variance))")
                means[light] = s.mean
            }
            if let day = means[.day], let night = means[.night] {
                check(night < day, "painting \(theme): night (\(night)) not darker than day (\(day))")
            }
        }

        // Every painted character and decoration ships, decodes, and is a cut-out (has alpha).
        for name in Art.paintedNames {
            guard let img = Art.image(name) else { check(false, "sprite \(name) is not in the app bundle"); continue }
            check(min(img.width, img.height) >= 24, "sprite \(name) is only \(img.width)x\(img.height)")
            check(![.none, .noneSkipFirst, .noneSkipLast].contains(img.alphaInfo), "sprite \(name) has no transparency")
        }

        // A window server that answers late must not hold the frame: the read gives up within its patience and
        // hands back the last list, starts no second ask meanwhile, and the late answer is there for a later read.
        var asks = 0
        let slow = WindowList { asks += 1; if asks > 1 { Thread.sleep(forTimeInterval: 0.2) }; return [["n": asks]] }
        let t0 = Date()
        let first = slow.read()?.first?["n"] as? Int
        let held = Date().timeIntervalSince(t0)
        let second = slow.read()?.first?["n"] as? Int
        Thread.sleep(forTimeInterval: 0.6)
        let third = slow.read()?.first?["n"] as? Int
        check(held < 0.15 && first == 1, "a late window server held the frame \(Int(held * 1000)) ms (list \(first ?? -1))")
        check(second == 1 && third == 2, "late window lists came back as \(second ?? -1), \(third ?? -1), not 1, 2")
        var quick = 0
        let fast = WindowList { quick += 1; return [["n": quick]] }
        check(fast.read(patience: 1)?.first?["n"] as? Int == 2, "a prompt window server's list was not this frame's")

        if failures.isEmpty {
            print("selfcheck: all \(count) checks passed")
            exit(0)
        }
        for f in failures { print("FAIL \(f)") }
        print("selfcheck: \(failures.count) of \(count) checks failed")
        exit(1)
    }

    /// Mean and variance of luminance, 0-255.
    private static func stats(_ img: CGImage) -> (mean: Double, variance: Double)? {
        let w = img.width, h = img.height
        guard let ctx = Art.bitmap(w, h) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let base = ctx.data else { return nil }
        let row = ctx.bytesPerRow
        let p = base.bindMemory(to: UInt8.self, capacity: row * h)
        var sum = 0.0, sq = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let i = y * row + x * 4
                let l = (Double(p[i]) + Double(p[i + 1]) + Double(p[i + 2])) / 3
                sum += l
                sq += l * l
            }
        }
        let n = Double(w * h)
        return (sum / n, sq / n - (sum / n) * (sum / n))
    }
}
