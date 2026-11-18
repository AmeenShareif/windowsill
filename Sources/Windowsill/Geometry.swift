import CoreGraphics
import Foundation

/// Pure geometry and simulation helpers. No AppKit, so `--selfcheck` covers them directly.
enum Geo {
    /// CGWindowList reports Quartz coordinates (origin top-left of the main screen, y down).
    /// AppKit and SpriteKit use Cocoa coordinates (origin bottom-left, y up).
    static func cocoa(fromQuartz r: CGRect, primaryHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// Is `p` hidden behind one of the windows stacked in front?
    static func covered<S: Sequence>(_ p: CGPoint, by front: S) -> Bool where S.Element == CGRect {
        front.contains { $0.contains(p) }
    }
}

/// A heightmap of settled snow along one surface (a window top, the Dock, the floor).
struct Pile {
    static let bucket: CGFloat = 4
    private(set) var heights: [CGFloat]
    let cap: CGFloat
    let maxStep: CGFloat

    init(width: CGFloat, cap: CGFloat, maxStep: CGFloat = 1.6) {
        heights = Array(repeating: 0, count: max(1, Int((width / Pile.bucket).rounded(.up))))
        self.cap = cap
        self.maxStep = maxStep
    }

    var total: CGFloat { heights.reduce(0, +) }
    var isEmpty: Bool { total < 0.01 }

    func index(_ x: CGFloat) -> Int { min(max(Int(x / Pile.bucket), 0), heights.count - 1) }
    func height(at x: CGFloat) -> CGFloat { heights[index(x)] }

    /// Drops snow at local x. A big flake is split into grains no taller than half the slope limit,
    /// so it spreads into a drift instead of stacking one column. Returns false when none of it sticks.
    @discardableResult
    mutating func add(at x: CGFloat, amount: CGFloat) -> Bool {
        let grain = maxStep / 2
        var left = amount, stuck = false
        while left > 0.0001 {
            stuck = addGrain(at: x, amount: min(grain, left)) || stuck
            left -= grain
        }
        return stuck
    }

    /// One grain rolls downhill while a neighbour is more than `maxStep` lower, and slides off either end.
    private mutating func addGrain(at x: CGFloat, amount: CGFloat) -> Bool {
        var i = index(x)
        let edge = -maxStep / 2      // the air past either end of the surface
        for _ in 0..<heights.count {
            let left = i > 0 ? heights[i - 1] : edge
            let right = i < heights.count - 1 ? heights[i + 1] : edge
            let goLeft = left < right || (left == right && Bool.random())
            guard heights[i] - (goLeft ? left : right) > maxStep else { break }
            i += goLeft ? -1 : 1
            if i < 0 || i >= heights.count { return false }
        }
        guard heights[i] < cap else { return false }
        heights[i] = min(cap, heights[i] + amount)
        return true
    }

    mutating func clear() {
        for i in heights.indices { heights[i] = 0 }
    }
}

/// The Christmas tree's silhouette in node-local points (origin at the trunk's base centre).
enum TreeShape {
    static let size = CGSize(width: 150, height: 205)
    /// Tiers from the bottom: base y, half-width at the base, apex y.
    static let tiers: [(base: CGFloat, half: CGFloat, apex: CGFloat)] = [
        (20, 70, 100), (58, 58, 138), (96, 45, 172), (132, 31, 200),
    ]
    static let apex = CGPoint(x: 0, y: 200)

    static func contains(_ p: CGPoint) -> Bool {
        tiers.contains { t in
            guard p.y >= t.base, p.y <= t.apex else { return false }
            return abs(p.x) <= t.half * (t.apex - p.y) / (t.apex - t.base)
        }
    }
}

/// Seeded generator so every time of day of one wallpaper theme shares its landscape.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
