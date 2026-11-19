import SpriteKit

// MARK: - The light the weather is drawn in, and the snow piles

extension WeatherScene {
    /// A colour as the weather's light shows it now (Sun.tint): the same at noon, warmer at sunset, dim at night.
    func lit(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat = 1) -> NSColor {
        NSColor(calibratedRed: r * tint.r, green: g * tint.g, blue: b * tint.b, alpha: alpha)
    }

    /// Weather that is drawn in the day's light: everything but what glows (stars, sparks, fireflies).
    static func isLit(_ e: Effect?) -> Bool { e == .snow || e == .leaves || e == .sakura || e == .rain }

    /// Follows the sun. Called twice a second; the light changes by less than a frame can show in that time,
    /// even on the demo's fast clock.
    func relight() {
        let t = Sun.tint(elevation: Sun.shared.lightElevation)
        let changed = abs(t.r - tint.r) + abs(t.g - tint.g) + abs(t.b - tint.b) > 0.004
        if changed { tint = t }
        let c = lit(1, 1, 1)
        if changed {
            for q in particles where Self.isLit(q.effect) { q.node.color = c }
            for n in pileNodes.values { colourPile(n) }
        }
        // Trees, snowmen, presents and visitors stand in the same light as the snow (at night they were noon
        // bright beside blue snow, CI 2026-11-19); every pass, so one placed since picks it up.
        let flying = Set(particles.map { ObjectIdentifier($0.node) })
        for layer in [deskLayer, decorLayer, visitorLayer] { Self.light(layer, c, skip: flying) }
    }

    /// Every sprite under `n` in the light `c`, but what glows: an added-light sprite (a bulb, a spark, its
    /// core) and whatever carries one (the star on its halo) keep their own colours, and so do particles
    /// (`skip`: smoke keeps its grey, lit snow is coloured as it spawns).
    static func light(_ n: SKNode, _ c: NSColor, skip: Set<ObjectIdentifier> = []) {
        for child in n.children where !skip.contains(ObjectIdentifier(child)) {
            if let s = child as? SKSpriteNode {
                if s.blendMode == .add || s.children.contains(where: { ($0 as? SKSpriteNode)?.blendMode == .add }) { continue }
                s.color = c
                s.colorBlendFactor = 1
            }
            light(child, c, skip: skip)
        }
    }

    private func colourPile(_ n: SKShapeNode) {
        n.fillColor = lit(0.97, 0.98, 1, alpha: 0.97)
        // A blue-grey rim, as shaded snow has, keeps a pile visible on a white window or a snowy wallpaper.
        n.strokeColor = lit(0.62, 0.71, 0.85, alpha: 0.95)
    }

    /// Every frame each pile is moved to its window (so snow rides a dragged window with no lag);
    /// its outline is only rebuilt every few frames, when it grows or a window in front moves, and
    /// every frame while the snow on it sways.
    func drawPiles(reshape: Bool) {
        let near = screenRect.insetBy(dx: 0, dy: -30)
        for (key, node) in pileNodes where engine.piles[key] == nil || surfaceByKey[key].map({ !$0.rect.intersects(near) }) ?? true {
            node.removeFromParent()
            pileNodes[key] = nil
        }
        for (key, pile) in engine.piles {
            guard let s = surfaceByKey[key], s.rect.intersects(near) else { continue }
            let fresh = pileNodes[key] == nil
            let node = pileNodes[key] ?? makePileNode(key)
            node.position = CGPoint(x: s.rect.minX - origin.x, y: s.top - origin.y)
            let lean = engine.sways[key]?.offset ?? .zero
            // Pressed down as its window starts up or stops coming down, heaped up the other way.
            node.yScale = 1 + lean.dy * 0.04
            // A window shaken or dragged in front moves ~20 pt a frame: cut around it every frame, or the
            // snow behind shows through it.
            let fronts = engine.snap.windows.prefix(min(s.order, engine.snap.windows.count)).map(\.frame)
            if fresh || reshape || lean.dx != 0 || pileFronts[key] != fronts {
                node.path = pilePath(pile, on: s, lean: lean.dx)
                pileFronts[key] = fronts
            }
        }
    }

    private func makePileNode(_ key: Int) -> SKShapeNode {
        let n = SKShapeNode()
        colourPile(n)
        n.lineWidth = 1.25
        pileLayer.addChild(n)
        pileNodes[key] = n
        return n
    }

    /// The pile's outline relative to the surface's top-left corner, split wherever a window in front hides it.
    /// On a window or the Dock it sits on the outline, so its ends follow the rounded corners down. Leaning by
    /// `lean` points, it shears: the deeper the snow, the further it goes, and where it lies on the window, none.
    private func pilePath(_ pile: Pile, on s: Surface, lean: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let h = pile.heights
        let b = Pile.bucket
        let w = s.rect.width, r = s.corner
        func base(_ x: CGFloat) -> CGFloat { -Pile.cornerDrop(at: x, width: w, radius: r) }
        func top(_ x: CGFloat, _ depth: CGFloat) -> CGPoint {
            CGPoint(x: x + lean * min(1, depth / 12), y: base(x) + depth)
        }
        let snap = engine.snap
        // Probed just under the top, so a window in front whose top is level with this one hides it too: its own
        // pile lies there, and this one's outline ran across its rounded corner (CI, 2026-11-18).
        let visible = h.indices.map { i in
            h[i] > 0.15 && !snap.isCovered(CGPoint(x: s.rect.minX + (CGFloat(i) + 0.5) * b, y: s.top - 1), behind: s)
        }
        var i = 0
        while i < h.count {
            guard visible[i] else { i += 1; continue }
            let start = i
            while i < h.count && visible[i] { i += 1 }
            let pts = (start..<i).map { j in top(min(w, (CGFloat(j) + 0.5) * b), h[j]) }
            let x0 = CGFloat(start) * b, x1 = min(w, CGFloat(i) * b)
            path.move(to: CGPoint(x: x0, y: base(x0)))
            path.addLine(to: top(x0, h[start] * 0.6))
            for k in 0..<(pts.count - 1) {
                let mid = CGPoint(x: (pts[k].x + pts[k + 1].x) / 2, y: (pts[k].y + pts[k + 1].y) / 2)
                path.addQuadCurve(to: mid, control: pts[k])
            }
            path.addLine(to: pts[pts.count - 1])
            path.addLine(to: top(x1, h[i - 1] * 0.6))
            path.addLine(to: CGPoint(x: x1, y: base(x1)))
            // Back along the window's outline, round any corner this run covers.
            if r > 0 {
                for x in Array(stride(from: w, through: w - r, by: -2)) + Array(stride(from: r, through: 0, by: -2))
                    where x < x1 && x > x0 {
                    path.addLine(to: CGPoint(x: x, y: base(x)))
                }
            }
            path.closeSubpath()
        }
        return path
    }
}
