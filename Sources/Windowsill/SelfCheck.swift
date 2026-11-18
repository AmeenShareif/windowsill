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

        // Coordinates.
        let flipped = Geo.cocoa(fromQuartz: CGRect(x: 10, y: 20, width: 100, height: 50), primaryHeight: 900)
        check(flipped == CGRect(x: 10, y: 830, width: 100, height: 50), "quartz to cocoa flip gave \(flipped)")
        let front = [CGRect(x: 0, y: 0, width: 50, height: 50), CGRect(x: 100, y: 100, width: 10, height: 10)]
        check(Geo.covered(CGPoint(x: 105, y: 105), by: front), "point inside a front window not covered")
        check(!Geo.covered(CGPoint(x: 75, y: 75), by: front), "point between windows reported covered")

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
