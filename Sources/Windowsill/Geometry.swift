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

/// How a window is moving, from the positions the engine samples. Those samples come from a timer
/// that beats against whatever moves the window (the mouse, another app), so one tick can see two
/// steps of a drag and the next none: speed read tick by tick swings between zero and double, and a
/// steady drag looks like a string of jolts. So speed is read over `span`, and a jolt is how much that
/// speed changed over the same span: a steady drag reads calm however it is sampled, while a sudden
/// stop or reversal reads as the whole change in speed.
struct Motion {
    static let span: TimeInterval = 0.07
    private var p = CGPoint.zero
    private var samples: [(t: TimeInterval, p: CGPoint)] = []
    private var speeds: [(t: TimeInterval, v: CGVector)] = []
    private(set) var velocity = CGVector.zero
    private var stillSamples = 0
    private var lead = CGVector.zero
    private var movedAt: TimeInterval?

    /// Records that the window moved by `d` since the last sample, at time `t`. Returns the jolt in
    /// points per second, and the velocity from before it, which is what loose snow keeps.
    mutating func add(moved d: CGVector, at t: TimeInterval) -> (jolt: CGFloat, before: CGVector) {
        stillSamples = d == .zero ? stillSamples + 1 : 0
        let last = samples.last?.t
        // A still sample a beat after a move is the beat; one longer after it is the window stopped.
        let stopped = d == .zero && (movedAt.map { t - $0 >= 0.025 } ?? true)
        if d != .zero { movedAt = t }
        p.x += d.dx
        p.y += d.dy
        samples.append((t, p))
        while samples.count > 2, t - samples[1].t >= Self.span { samples.removeFirst() }
        let a = samples[0]
        velocity = t > a.t ? CGVector(dx: (p.x - a.p.x) / (t - a.t), dy: (p.y - a.p.y) / (t - a.t)) : .zero
        // Led at the speed read over `span` alone, a flung window that stopped dead still read as moving for
        // a tick or two, and its snow ran on past it (CI, 2026-11-19). So the lead goes no faster than twice
        // this step (a beat sees half a step, a dead stop a sliver), and a still sample never raises it.
        let speed = hypot(velocity.dx, velocity.dy)
        var cap = speed
        if stopped {
            cap = 0
        } else if d == .zero {
            cap = hypot(lead.dx, lead.dy)
        } else if let l = last, t > l {
            cap = 2 * hypot(d.dx, d.dy) / CGFloat(t - l)
        }
        let k = speed > cap ? cap / speed : 1
        lead = CGVector(dx: velocity.dx * k, dy: velocity.dy * k)
        speeds.append((t, velocity))
        while speeds.count > 2, t - speeds[1].t >= Self.span { speeds.removeFirst() }
        let before = speeds[0].v
        return (hypot(velocity.dx - before.dx, velocity.dy - before.dy), before)
    }

    /// How far the window goes in `t` seconds at its present speed: nowhere once two samples in a row saw
    /// it still. The speed read over `span` remembers a motion for a few frames after it stops dead, and
    /// a flung window's snow ran on ahead of it for those frames (CI, 2026-11-18); a single still sample
    /// is only the beat, mid-drag.
    func ahead(_ t: CGFloat) -> CGVector { stillSamples >= 2 ? .zero : CGVector(dx: lead.dx * t, dy: lead.dy * t) }

    /// Share of a pile a jolt of `j` points per second shakes loose over `dt` seconds: none for any
    /// drag a person makes on purpose, nearly all of it for a flick that stops dead.
    static func shake(_ j: CGFloat, dt: CGFloat) -> CGFloat { min(1, max(0, j - 450) / 50 * dt) }
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

    /// Takes all but `keep` (a share) of the snow in the bucket under local x; returns the depth taken.
    mutating func take(at x: CGFloat, keep: CGFloat) -> CGFloat {
        let i = index(x), off = heights[i] * (1 - min(max(keep, 0), 1))
        heights[i] -= off
        return off
    }

    /// Where two snowballs can be rolled on this pile and stacked into a snowman. The bottom ball rolls
    /// to `stand` from one side and must gather `need.bottom` square points of snow on the way; the top
    /// ball rolls in from the other side, stopping `gap` short of the stand, and must gather `need.top`.
    /// A ball takes all but `keep` of the snow it rolls over. Neither may roll over a blocked x (other
    /// things, snow out of sight), nor may the snowman stand within `footprint` of one. Picks the plan
    /// with the least rolling: local xs of the stand and of where each ball starts, or nil.
    func snowmanPlan(need: (bottom: CGFloat, top: CGFloat), gap: CGFloat, footprint: CGFloat, keep: CGFloat,
                     blocked: (CGFloat) -> Bool) -> (stand: CGFloat, bottom: CGFloat, top: CGFloat)? {
        let b = Pile.bucket, n = heights.count
        func x(_ i: Int) -> CGFloat { (CGFloat(i) + 0.5) * b }
        let wall = (0..<n).map { blocked(x($0)) }
        let gain = heights.map { $0 * (1 - keep) * b }
        // Walking from bucket i by `step`, the bucket where `need` has been gathered; nil at a wall or the end.
        func reach(from i: Int, step: Int, need: CGFloat) -> Int? {
            var got: CGFloat = 0, j = i
            while j >= 0 && j < n && !wall[j] {
                got += gain[j]
                if got >= need { return j }
                j += step
            }
            return nil
        }
        let half = Int((footprint / b).rounded(.up)), off = Int((gap / b).rounded())
        guard n > 2 * half else { return nil }
        var best: (cost: Int, plan: (stand: CGFloat, bottom: CGFloat, top: CGFloat))?
        for s in half..<(n - half) where !(s - half...s + half).contains(where: { wall[$0] }) {
            for step in [-1, 1] {
                guard let a = reach(from: s, step: step, need: need.bottom),
                      let c = reach(from: s - step * off, step: -step, need: need.top) else { continue }
                let cost = abs(a - s) + abs(c - s)
                if cost < best?.cost ?? .max { best = (cost, (x(s), x(a), x(c))) }
            }
        }
        return best?.plan
    }

    /// Settled snow thaws by a share of its depth plus a little: a light fall settles thinner than a
    /// heavy one, and a full pile left alone is gone in about four and a half minutes.
    mutating func melt(_ dt: CGFloat) {
        for i in heights.indices { heights[i] = max(0, heights[i] - (heights[i] * 0.01 + 0.01) * dt) }
    }

    /// A window's top corners are rounded, so its top edge falls away near either end. How far below
    /// the top edge the window's outline is at local x: snow there follows the corner down instead of
    /// hanging in the air past it.
    static func cornerDrop(at x: CGFloat, width w: CGFloat, radius r: CGFloat) -> CGFloat {
        let e = r - max(0, min(x, w - x))
        guard r > 0, e > 0 else { return 0 }
        return r - (r * r - e * e).squareRoot()
    }

    /// The corner radius macOS 26 gives a titled window.
    static let windowCorner: CGFloat = 16

    /// Takes `fraction` of every bucket off the pile (a jolt shakes it loose) and returns what came off.
    mutating func shed(_ fraction: CGFloat) -> [CGFloat] {
        let f = min(max(fraction, 0), 1)
        guard f > 0 else { return [] }
        return heights.indices.map { i in
            let off = heights[i] * f
            heights[i] -= off
            return off
        }
    }

    /// The window was resized from `old` to `new`. Snow keeps its place along the edge that stayed put,
    /// and whatever lay past a moved edge comes off: returned as each bucket's global x and height.
    mutating func refit(from old: CGRect, to new: CGRect) -> [(x: CGFloat, h: CGFloat)] {
        let n = max(1, Int((new.width / Pile.bucket).rounded(.up)))
        guard n != heights.count else { return [] }
        let fromLeft = abs(new.maxX - old.maxX) < 0.5 && abs(new.minX - old.minX) >= 0.5
        let shift = fromLeft ? heights.count - n : 0
        var kept = Array(repeating: CGFloat(0), count: n)
        var fallen: [(x: CGFloat, h: CGFloat)] = []
        for (j, h) in heights.enumerated() where h > 0 {
            let i = j - shift
            if i >= 0 && i < n { kept[i] = h } else { fallen.append((old.minX + (CGFloat(j) + 0.5) * Pile.bucket, h)) }
        }
        heights = kept
        return fallen
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

/// How far each of a row of things moves this step so none overlap: every overlapping pair standing on
/// the same thing (`together`) is pushed apart, half the overlap each and at most `limit`. Something
/// `fixed` (a tree) never moves: the other one takes the whole overlap.
func shoves(_ xs: [CGFloat], halves: [CGFloat], fixed: Set<Int> = [], limit: CGFloat,
            together: (Int, Int) -> Bool) -> [CGFloat] {
    var push = [CGFloat](repeating: 0, count: xs.count)
    for a in xs.indices {
        for b in xs.indices where b > a && together(a, b) && !(fixed.contains(a) && fixed.contains(b)) {
            let overlap = halves[a] + halves[b] - abs(xs[a] - xs[b])
            guard overlap > 0.5 else { continue }
            let share: CGFloat = fixed.contains(a) || fixed.contains(b) ? 1 : 0.5
            let step = min(overlap * share, limit) * (xs[a] <= xs[b] ? -1 : 1)
            if !fixed.contains(a) { push[a] += step }
            if !fixed.contains(b) { push[b] -= step }
        }
    }
    return push
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
