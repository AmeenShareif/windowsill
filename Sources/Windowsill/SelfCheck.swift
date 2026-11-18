import CoreGraphics
import Foundation
import ImageIO

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

        // The engine's tick beats against whatever drags a window, so now and then it sees no move,
        // then two. That is still a steady drag: snow and presents ride it. A flick that stops dead
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

        // Clock to time of day, including the edges.
        let hours: [(Double, TimeOfDay)] = [(2, .night), (4.49, .night), (4.5, .dawn), (6.5, .sunrise), (9, .morning),
                                            (12, .midday), (16, .golden), (17.5, .sunset), (19, .dusk), (20, .night), (23.9, .night)]
        for (hour, want) in hours {
            check(TimeOfDay.at(hour: hour) == want, "hour \(hour) gave \(TimeOfDay.at(hour: hour)), want \(want)")
        }

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

        // Every painting ships in the bundle, decodes, is big enough for a desktop and is darker at night.
        for theme in Theme.allCases {
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
