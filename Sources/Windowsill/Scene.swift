import SpriteKit
import AppKit

struct Particle {
    enum Phase { case falling, free, resting }
    let node: SKSpriteNode
    var p: CGPoint
    var v: CGVector
    var phase: Phase
    let effect: Effect?            // nil for sparks, splashes, confetti, smoke
    var seed: CGFloat = .random(in: 0...1)
    var terminal: CGFloat = 80
    var spin: CGFloat = 0
    var life: CGFloat = .infinity
    var maxLife: CGFloat = 1
    var gravity: CGFloat = 0
    var grow: CGFloat = 0
    var noLand: CGFloat = 0
    var surface: Int? = nil
    var restX: CGFloat = 0
    var restY: CGFloat = 0
    var dead = false
}

/// How each effect moves: sideways sway, how fast it settles to its fall speed, how much wind moves it.
private struct Feel {
    let wobble: CGFloat, drag: CGFloat, windGain: CGFloat, fallSpeed: CGFloat, rate: CGFloat

    static func of(_ e: Effect) -> Feel {
        switch e {
        case .snow: return Feel(wobble: 16, drag: 1.4, windGain: 120, fallSpeed: 75, rate: 45)
        case .leaves: return Feel(wobble: 55, drag: 1.1, windGain: 170, fallSpeed: 82, rate: 3.2)
        case .sakura: return Feel(wobble: 38, drag: 1.3, windGain: 140, fallSpeed: 47, rate: 7)
        case .rain: return Feel(wobble: 0, drag: 3, windGain: 260, fallSpeed: 820, rate: 150)
        case .starfall: return Feel(wobble: 0, drag: 0, windGain: 0, fallSpeed: 0, rate: 0.8)
        case .fireflies: return Feel(wobble: 0, drag: 0, windGain: 0, fallSpeed: 0, rate: 0)
        }
    }
}

final class WeatherScene: SKScene {
    let origin: CGPoint            // this screen's bottom-left in global coordinates
    let screenIndex: Int
    let engine = Engine.shared
    var particles: [Particle] = []
    var pileNodes: [Int: SKShapeNode] = [:]
    let pileLayer = SKNode(), fxLayer = SKNode(), decorLayer = SKNode(), visitorLayer = SKNode()
    /// Things on the floor (trees, the train, a Yeti on foot) stand behind your windows, like desktop
    /// widgets: the hole layer above them erases every window's rectangle back to transparent, so the
    /// app window under the overlay shows through. Everything above the holes draws in front.
    let deskLayer = SKNode(), holeLayer = SKNode()
    private var holes: [SKSpriteNode] = []
    private let cursor = SKSpriteNode(texture: Art.cursor, size: Art.cursorSize)
    var surfaceByKey: [Int: Surface] = [:]
    private var lastUpdate: TimeInterval = 0
    private(set) var clock: CGFloat = 0
    private var spawnDebt: CGFloat = 0
    private var frameCount = 0
    private var shownEffect: Effect?
    private var nextLightning: CGFloat = .random(in: 6...14)
    private static let maxParticles = 1800
    private static let maxResting = 220

    var mouse = CGPoint(x: -9999, y: -9999)
    var mouseV = CGVector.zero
    var mouseStill: CGFloat = 0
    var mouseSpeed: CGFloat { hypot(mouseV.dx, mouseV.dy) }

    // Decorations and visitors live in Christmas.swift.
    var treeNodes: [UUID: TreeNode] = [:]
    var snowmanNodes: [UUID: SKNode] = [:]
    var presentNodes: [UUID: SKNode] = [:]
    var visitors: [Visitor] = []
    var drag: DragState?

    var screenRect: CGRect { CGRect(origin: origin, size: size) }

    init(size: CGSize, origin: CGPoint, screenIndex: Int) {
        self.origin = origin
        self.screenIndex = screenIndex
        super.init(size: size)
        backgroundColor = .clear
        scaleMode = .resizeFill
        deskLayer.zPosition = 1
        holeLayer.zPosition = 8          // deskLayer descendants must stay below this (they reach about +6)
        pileLayer.zPosition = 9
        fxLayer.zPosition = 10
        decorLayer.zPosition = 11
        visitorLayer.zPosition = 20
        cursor.zPosition = 100
        cursor.anchorPoint = Art.cursorTip
        cursor.isHidden = true
        [deskLayer, holeLayer, pileLayer, fxLayer, decorLayer, visitorLayer, cursor].forEach { addChild($0) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func local(_ g: CGPoint) -> CGPoint { CGPoint(x: g.x - origin.x, y: g.y - origin.y) }
    func global(_ l: CGPoint) -> CGPoint { CGPoint(x: l.x + origin.x, y: l.y + origin.y) }

    override func update(_ currentTime: TimeInterval) {
        let dt = CGFloat(lastUpdate == 0 ? 1.0 / 60 : min(0.1, currentTime - lastUpdate))
        lastUpdate = currentTime
        clock += dt
        frameCount += 1
        surfaceByKey = Dictionary(engine.snap.surfaces.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        trackMouse(dt)
        let st = engine.state
        let want: Effect? = st.enabled ? st.effect : nil
        if want != shownEffect { switchEffect(to: want) }
        if let e = want, particles.count < Self.maxParticles { spawn(e, dt: dt) }
        stepParticles(dt)
        if want == .rain { stepLightning(dt) }
        drawPiles(reshape: frameCount % 3 == 0)
        updateDecor(dt)
        cutHoles()
        if let p = engine.pointerOverride {
            cursor.isHidden = false
            cursor.position = local(p)
        } else {
            cursor.isHidden = true
        }
    }

    /// Is this local point inside one of the app windows?
    func overWindow(_ p: CGPoint) -> Bool {
        let g = global(p)
        return engine.snap.windows.contains { $0.frame.contains(g) }
    }

    private func cutHoles() {
        let frames = deskLayer.children.isEmpty ? [] : engine.snap.windows.map(\.frame).filter { $0.intersects(screenRect) }
        while holes.count < frames.count {
            let n = SKSpriteNode(texture: Art.clear, size: .zero)
            n.anchorPoint = .zero
            n.blendMode = .replace
            holeLayer.addChild(n)
            holes.append(n)
        }
        for (i, n) in holes.enumerated() {
            n.isHidden = i >= frames.count
            guard i < frames.count else { continue }
            n.position = local(frames[i].origin)
            n.size = frames[i].size
        }
    }

    /// A ring where the scripted pointer clicks, so a recording shows the click.
    func showClick(at p: CGPoint) {
        let ring = SKShapeNode(circleOfRadius: 14)
        ring.strokeColor = NSColor(calibratedRed: 1, green: 0.85, blue: 0.3, alpha: 1)
        ring.lineWidth = 3
        ring.position = p
        ring.zPosition = 99
        addChild(ring)
        ring.setScale(0.3)
        ring.run(.sequence([.group([.scale(to: 1.6, duration: 0.35), .fadeOut(withDuration: 0.35)]), .removeFromParent()]))
    }

    private func trackMouse(_ dt: CGFloat) {
        let m = engine.pointer
        let p = local(m)
        let v = CGVector(dx: (p.x - mouse.x) / dt, dy: (p.y - mouse.y) / dt)
        if abs(v.dx) > 30000 || abs(v.dy) > 30000 {
            mouseV = .zero
        } else {
            mouseV = CGVector(dx: mouseV.dx * 0.5 + v.dx * 0.5, dy: mouseV.dy * 0.5 + v.dy * 0.5)
        }
        mouseStill = hypot(p.x - mouse.x, p.y - mouse.y) < 1.5 ? mouseStill + dt : 0
        mouse = p
    }

    // MARK: - Spawning

    private var density: CGFloat {
        CGFloat(engine.state.intensity) * (engine.lowPower ? 0.5 : 1) * size.width / 1440
    }

    private func switchEffect(to e: Effect?) {
        for q in particles {
            q.node.run(.sequence([.fadeOut(withDuration: 0.8), .removeFromParent()]))
        }
        particles.removeAll()
        engine.piles.removeAll()
        pileNodes.values.forEach { $0.run(.sequence([.fadeOut(withDuration: 0.8), .removeFromParent()])) }
        pileNodes.removeAll()
        shownEffect = e
        // Start mid-storm rather than with an empty sky.
        guard let e, Feel.of(e).fallSpeed > 0 else { return }
        let count = Int(Feel.of(e).rate * density * size.height / Feel.of(e).fallSpeed)
        for _ in 0..<min(count, 900) { spawnFalling(e, y: .random(in: 0...size.height)) }
    }

    private func spawn(_ e: Effect, dt: CGFloat) {
        if e == .fireflies {
            let have = particles.lazy.filter { $0.effect == .fireflies }.count
            if have < Int(30 * density), CGFloat.random(in: 0...1) < dt * 6 { spawnFirefly() }
            return
        }
        spawnDebt += Feel.of(e).rate * density * dt
        while spawnDebt >= 1 {
            spawnDebt -= 1
            spawnFalling(e, y: size.height + 24)
        }
    }

    func sprite(_ t: SKTexture, size s: CGSize, layer: SKNode? = nil) -> SKSpriteNode {
        let n = SKSpriteNode(texture: t, size: s)
        (layer ?? fxLayer).addChild(n)
        return n
    }

    func add(_ q: Particle) {
        q.node.position = q.p
        particles.append(q)
    }

    private func spawnFalling(_ e: Effect, y: CGFloat) {
        let w = size.width
        let wind = CGFloat(engine.state.wind)
        var p = CGPoint(x: .random(in: -0.15...1.15) * w, y: y)
        switch e {
        case .snow:
            let s = CGFloat.random(in: 2...5.5)
            let n = sprite(Art.flake, size: CGSize(width: s * 2, height: s * 2))
            n.alpha = .random(in: 0.7...1)
            add(Particle(node: n, p: p, v: CGVector(dx: 0, dy: -(38 + s * 13)), phase: .falling, effect: e,
                         terminal: 38 + s * 13))
        case .leaves:
            let s = CGFloat.random(in: 15...24)
            let leaf = Art.leaves.randomElement()!
            let n = sprite(leaf, size: Art.fit(leaf, height: s))
            n.zRotation = .random(in: 0...6.28)
            add(Particle(node: n, p: p, v: CGVector(dx: 0, dy: -80), phase: .falling, effect: e,
                         terminal: .random(in: 70...95), spin: .random(in: -3...3)))
        case .sakura:
            let s = CGFloat.random(in: 9...14)
            let petal = Art.petals.randomElement()!
            let n = sprite(petal, size: Art.fit(petal, height: s))
            n.zRotation = .random(in: 0...6.28)
            add(Particle(node: n, p: p, v: CGVector(dx: 0, dy: -45), phase: .falling, effect: e,
                         terminal: .random(in: 40...55), spin: .random(in: -2.5...2.5)))
        case .rain:
            let n = sprite(Art.streak, size: CGSize(width: .random(in: 14...24), height: 1.4))
            n.color = NSColor(calibratedRed: 0.78, green: 0.86, blue: 1, alpha: 1)
            n.colorBlendFactor = 1
            n.alpha = .random(in: 0.35...0.65)
            let t = CGFloat.random(in: 760...900)
            add(Particle(node: n, p: p, v: CGVector(dx: wind * 260, dy: -t), phase: .falling, effect: e, terminal: t))
        case .starfall:
            let right = wind > 0.15
            p.x = (right ? CGFloat.random(in: -0.35...0.85) : .random(in: 0.15...1.35)) * w
            let speed = CGFloat.random(in: 380...560)
            let ang = CGFloat.random(in: 200...235) * .pi / 180
            let v = CGVector(dx: cos(ang) * speed * (right ? -1 : 1), dy: sin(ang) * speed)
            let n = sprite(Art.streak, size: CGSize(width: .random(in: 70...110), height: 3))
            n.blendMode = .add
            n.color = NSColor(calibratedRed: 1, green: 0.95, blue: 0.8, alpha: 1)
            n.colorBlendFactor = 1
            let head = SKSpriteNode(texture: Art.glow, size: CGSize(width: 14, height: 14))
            head.position = CGPoint(x: n.size.width / 2, y: 0)
            head.blendMode = .add
            n.addChild(head)
            n.zRotation = atan2(v.dy, v.dx)
            add(Particle(node: n, p: p, v: v, phase: .falling, effect: e))
        case .fireflies:
            break
        }
    }

    private func spawnFirefly() {
        let n = sprite(Art.glow, size: CGSize(width: 28, height: 28))
        n.color = NSColor(calibratedRed: 0.85, green: 1, blue: 0.45, alpha: 1)
        n.colorBlendFactor = 1
        n.blendMode = .add
        n.alpha = 0
        let core = SKSpriteNode(texture: Art.glow, size: CGSize(width: 8, height: 8))   // the bright body
        core.color = NSColor(calibratedRed: 1, green: 1, blue: 0.8, alpha: 1)
        core.colorBlendFactor = 1
        core.blendMode = .add
        n.addChild(core)
        let p = CGPoint(x: .random(in: 20...(size.width - 20)), y: .random(in: 20...(size.height - 20)))
        add(Particle(node: n, p: p, v: CGVector(dx: .random(in: -20...20), dy: .random(in: -20...20)),
                     phase: .free, effect: .fireflies))
    }

    /// A short-lived particle that ignores surfaces: sparks, splashes, confetti, smoke, sleigh glitter.
    func emit(_ t: SKTexture, at p: CGPoint, v: CGVector, life: CGFloat, size s: CGSize, color: NSColor,
              gravity: CGFloat = 0, additive: Bool = false, spin: CGFloat = 0, grow: CGFloat = 0,
              layer: SKNode? = nil) {
        let n = sprite(t, size: s, layer: layer)
        n.color = color
        n.colorBlendFactor = 1
        if additive { n.blendMode = .add }
        add(Particle(node: n, p: p, v: v, phase: .free, effect: nil, spin: spin, life: life, maxLife: life,
                     gravity: gravity, grow: grow))
    }

    // MARK: - Simulation

    private func stepParticles(_ dt: CGFloat) {
        let wind = CGFloat(engine.state.wind)
        for i in particles.indices {
            var q = particles[i]
            switch q.phase {
            case .falling: stepFalling(&q, dt, wind)
            case .free: stepFree(&q, dt)
            case .resting: stepResting(&q, dt)
            }
            if q.life.isFinite {
                q.life -= dt
                if q.life <= 0 { q.dead = true }
            }
            q.node.position = q.p
            particles[i] = q
        }
        for q in particles where q.dead { q.node.removeFromParent() }
        particles.removeAll { $0.dead }
    }

    private func stepFalling(_ q: inout Particle, _ dt: CGFloat, _ wind: CGFloat) {
        guard let e = q.effect else { return }
        let f = Feel.of(e)
        if f.drag > 0 {
            let wob = sin(clock * (1.1 + q.seed) + q.seed * 6.283) * f.wobble
            let k = min(1, f.drag * dt)
            q.v.dx += (wind * f.windGain + wob - q.v.dx) * k
            q.v.dy += (-q.terminal - q.v.dy) * k
        }
        let old = q.p
        q.p.x += q.v.dx * dt
        q.p.y += q.v.dy * dt
        if q.spin != 0 {
            q.node.zRotation += q.spin * dt
            q.node.xScale = 0.55 + 0.45 * abs(sin(clock * 2 + q.seed * 9))   // flutter
        }
        if e == .rain || e == .starfall { q.node.zRotation = atan2(q.v.dy, q.v.dx) }
        if q.noLand > 0 {
            q.noLand -= dt
        } else if q.v.dy < 0, let hit = landing(from: old, to: q.p, effect: e) {
            land(&q, on: hit.surface, top: hit.top)
        }
        if q.p.y < -60 || q.p.x < -0.4 * size.width || q.p.x > 1.4 * size.width { q.dead = true }
    }

    /// The first surface, front to back, whose visible top edge the particle crossed this frame.
    private func landing(from a: CGPoint, to b: CGPoint, effect: Effect) -> (surface: Surface, top: CGFloat)? {
        let gx = b.x + origin.x
        let y0 = a.y + origin.y, y1 = b.y + origin.y
        let snap = engine.snap
        for s in snap.surfaces where gx >= s.rect.minX && gx <= s.rect.maxX {
            var top = s.top
            if effect == .snow, let pile = engine.piles[s.key] { top += pile.height(at: gx - s.rect.minX) }
            guard y0 >= top, y1 < top else { continue }
            if !snap.isCovered(CGPoint(x: gx, y: s.top + 1), behind: s) { return (s, top) }
        }
        return nil
    }

    private func land(_ q: inout Particle, on s: Surface, top: CGFloat) {
        let gx = q.p.x + origin.x
        let at = CGPoint(x: q.p.x, y: top - origin.y)
        switch q.effect {
        case .snow?:
            var pile = engine.piles[s.key] ?? Pile(width: s.rect.width, cap: s.cap)
            pile.add(at: gx - s.rect.minX, amount: q.node.size.width * 0.16 * engine.pileBoost)
            engine.piles[s.key] = pile
            q.dead = true
        case .leaves?, .sakura?:
            q.phase = .resting
            q.surface = s.key
            q.restX = gx - s.rect.minX
            q.restY = .random(in: 0...2.5)
            q.v = .zero
            q.node.zRotation = .random(in: -0.5...0.5)
            q.node.xScale = 1
            q.node.yScale = 0.6
            if q.effect == .sakura {
                q.life = .random(in: 15...40)
                q.maxLife = q.life
            }
            retireOldestResting()
        case .rain?:
            q.dead = true
            for _ in 0..<3 {
                emit(Art.flake, at: at, v: CGVector(dx: .random(in: -70...70), dy: .random(in: 70...170)),
                     life: 0.35, size: CGSize(width: 2.6, height: 2.6),
                     color: NSColor(calibratedRed: 0.8, green: 0.88, blue: 1, alpha: 1), gravity: 900)
            }
        case .starfall?:
            q.dead = true
            for _ in 0..<14 {
                let a = CGFloat.random(in: 0.15...(.pi - 0.15)), sp = CGFloat.random(in: 80...260)
                emit(Art.glow, at: at, v: CGVector(dx: cos(a) * sp, dy: sin(a) * sp), life: .random(in: 0.5...0.9),
                     size: CGSize(width: 7, height: 7),
                     color: [NSColor.white, NSColor(calibratedRed: 1, green: 0.85, blue: 0.4, alpha: 1)].randomElement()!,
                     gravity: 380, additive: true)
            }
        default:
            q.dead = true
        }
    }

    private func retireOldestResting() {
        var resting = 0
        for q in particles where q.phase == .resting && !q.dead { resting += 1 }
        guard resting > Self.maxResting,
              let i = particles.firstIndex(where: { $0.phase == .resting && !$0.dead }) else { return }
        particles[i].dead = true
    }

    private func stepFree(_ q: inout Particle, _ dt: CGFloat) {
        if q.effect == .fireflies { stepFirefly(&q, dt); return }
        q.v.dy -= q.gravity * dt
        q.p.x += q.v.dx * dt
        q.p.y += q.v.dy * dt
        if q.spin != 0 { q.node.zRotation += q.spin * dt }
        if q.life.isFinite {
            let left = max(0, q.life / q.maxLife)
            q.node.alpha = min(1, left * 2)
            if q.grow != 0 { q.node.setScale(1 + q.grow * (1 - left)) }
        }
    }

    private func stepFirefly(_ q: inout Particle, _ dt: CGFloat) {
        let onScreen = mouse.x >= 0 && mouse.x <= size.width && mouse.y >= 0 && mouse.y <= size.height
        if onScreen && mouseStill > 0.8 {
            // Gather in a loose swarm around a resting pointer.
            let ang = q.seed * 6.283 + clock * (0.4 + q.seed * 0.5)
            let r = 26 + q.seed * 60
            let tx = mouse.x + cos(ang) * r, ty = mouse.y + sin(ang) * r
            q.v.dx += ((tx - q.p.x) * 2.2 - q.v.dx * 1.6) * dt
            q.v.dy += ((ty - q.p.y) * 2.2 - q.v.dy * 1.6) * dt
        } else {
            q.v.dx += .random(in: -70...70) * dt
            q.v.dy += .random(in: -70...70) * dt
        }
        let d = hypot(q.p.x - mouse.x, q.p.y - mouse.y)
        if mouseSpeed > 600, d < 170, d > 1 {
            q.v.dx += (q.p.x - mouse.x) / d * 2200 * dt
            q.v.dy += (q.p.y - mouse.y) / d * 2200 * dt
        }
        let sp = hypot(q.v.dx, q.v.dy), cap: CGFloat = mouseStill > 0.8 ? 140 : 45
        if sp > cap {
            let f = max(cap / sp, 1 - 1.5 * dt)
            q.v.dx *= f
            q.v.dy *= f
        }
        if q.p.x < 10 { q.v.dx += 80 * dt }
        if q.p.x > size.width - 10 { q.v.dx -= 80 * dt }
        if q.p.y < 10 { q.v.dy += 80 * dt }
        if q.p.y > size.height - 10 { q.v.dy -= 80 * dt }
        q.p.x += q.v.dx * dt
        q.p.y += q.v.dy * dt
        let pulse = 0.5 + 0.5 * sin(clock * (1.3 + q.seed) + q.seed * 20)
        q.node.alpha = 0.2 + 0.8 * pulse * pulse
    }

    private func stepResting(_ q: inout Particle, _ dt: CGFloat) {
        guard let key = q.surface, let s = surfaceByKey[key] else { q.dead = true; return }
        let g = CGPoint(x: s.rect.minX + q.restX, y: s.top + q.restY)
        q.p = local(g)
        q.node.isHidden = engine.snap.isCovered(CGPoint(x: g.x, y: s.top + 1), behind: s)
        if q.life.isFinite, q.life < 3 { q.node.alpha = max(0, q.life / 3) }
        if mouseSpeed > 280, !q.node.isHidden, hypot(q.p.x - mouse.x, q.p.y - mouse.y) < 48 {
            launch(&q, velocity: CGVector(dx: mouseV.dx * 0.45, dy: abs(mouseV.dy) * 0.2 + .random(in: 140...280)))
        }
    }

    private func launch(_ q: inout Particle, velocity v: CGVector) {
        q.phase = .falling
        q.surface = nil
        q.v = CGVector(dx: v.dx + .random(in: -40...40), dy: v.dy)
        q.noLand = 0.3
        q.life = .infinity
        q.node.alpha = 1
        q.node.yScale = 1
        q.node.isHidden = false
    }

    // MARK: - Events from the window tracker

    /// A window moved. Its snow rides along (the pile is drawn where the window is now); a jolt shakes
    /// a share of it loose, a resize drops what lay past the moved edge, and resting leaves are shaken
    /// off with the same odds. What falls keeps the window's speed, so a flung window throws its snow.
    func surfaceMoved(_ key: Int, top: CGFloat, fallen: [(x: CGFloat, h: CGFloat)], velocity raw: CGVector, shake: CGFloat) {
        let v = Self.capped(raw, 1600)
        if shake > 0 {
            for i in particles.indices where particles[i].phase == .resting && particles[i].surface == key
                && CGFloat.random(in: 0...1) < shake {
                launch(&particles[i], velocity: CGVector(dx: v.dx * 0.7, dy: max(v.dy * 0.7, 0) + .random(in: 60...160)))
            }
        }
        burst(fallen, top: top, velocity: v)
    }

    /// A window closed or minimised: what lay on it drops where it was. After a Space switch every
    /// window "closes" at once, so then it quietly goes instead of snowing on the new Space.
    func surfaceGone(_ key: Int, top: CGFloat, fallen: [(x: CGFloat, h: CGFloat)], quiet: Bool) {
        for i in particles.indices where particles[i].surface == key {
            if quiet { particles[i].dead = true } else { launch(&particles[i], velocity: .zero) }
        }
        pileNodes.removeValue(forKey: key)?.removeFromParent()
        burst(fallen, top: top, velocity: .zero)
    }

    private static func capped(_ v: CGVector, _ m: CGFloat) -> CGVector {
        let mag = hypot(v.dx, v.dy)
        return mag > m ? CGVector(dx: v.dx / mag * m, dy: v.dy / mag * m) : v
    }

    /// Loose snow, one flake per couple of points of depth, starting where it lay.
    private func burst(_ grains: [(x: CGFloat, h: CGFloat)], top: CGFloat, velocity v: CGVector) {
        var budget = 420
        for g in grains where g.h > 0.05 && budget > 0 {
            let n = min(Int((g.h / 2.2).rounded(.up)), budget)
            budget -= n
            for _ in 0..<n {
                let p = local(CGPoint(x: g.x + .random(in: -2...2), y: top + .random(in: 0...max(g.h, 1))))
                guard p.x >= 0, p.x <= size.width, p.y >= 0, p.y <= size.height + 40 else { continue }
                let s = CGFloat.random(in: 2...5)
                let node = sprite(Art.flake, size: CGSize(width: s * 2, height: s * 2))
                add(Particle(node: node, p: p,
                             v: CGVector(dx: v.dx * .random(in: 0.55...0.95) + .random(in: -40...40),
                                         dy: v.dy * .random(in: 0.4...0.8) + .random(in: 20...110)),
                             phase: .falling, effect: .snow, terminal: 38 + s * 13, noLand: 0.35))
            }
        }
    }

    // MARK: - Lightning

    private func stepLightning(_ dt: CGFloat) {
        nextLightning -= dt
        guard nextLightning <= 0 else { return }
        nextLightning = .random(in: 8...24) / CGFloat(max(0.3, engine.state.intensity))
        // A full-screen flicker is exactly what Reduce Motion asks apps to leave out; the bolt stays.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let flash = SKSpriteNode(color: .white, size: size)
            flash.anchorPoint = .zero
            flash.alpha = 0
            flash.zPosition = 12
            addChild(flash)
            flash.run(.sequence([.fadeAlpha(to: 0.28, duration: 0.05), .fadeAlpha(to: 0.05, duration: 0.08),
                                 .fadeAlpha(to: 0.22, duration: 0.05), .fadeOut(withDuration: 0.5), .removeFromParent()]))
        }
        let path = CGMutablePath()
        var p = CGPoint(x: .random(in: 0.15...0.85) * size.width, y: size.height)
        path.move(to: p)
        let end = size.height * .random(in: 0.2...0.5)
        while p.y > end {
            p = CGPoint(x: p.x + .random(in: -28...28), y: p.y - .random(in: 14...34))
            path.addLine(to: p)
        }
        let bolt = SKShapeNode(path: path)
        bolt.strokeColor = NSColor(calibratedRed: 0.92, green: 0.95, blue: 1, alpha: 1)
        bolt.lineWidth = 2.2
        bolt.glowWidth = 6
        bolt.zPosition = 12
        addChild(bolt)
        bolt.run(.sequence([.wait(forDuration: 0.12), .fadeOut(withDuration: 0.35), .removeFromParent()]))
    }

    // MARK: - Snow piles

    /// Every frame each pile is moved to its window (so snow rides a dragged window with no lag);
    /// its outline is only rebuilt every few frames, when it grows or a window in front moves.
    private func drawPiles(reshape: Bool) {
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
            if fresh || reshape { node.path = pilePath(pile, on: s) }
        }
    }

    private func makePileNode(_ key: Int) -> SKShapeNode {
        let n = SKShapeNode()
        n.fillColor = NSColor(calibratedRed: 0.97, green: 0.98, blue: 1, alpha: 0.97)
        n.strokeColor = NSColor(calibratedRed: 0.76, green: 0.83, blue: 0.93, alpha: 0.9)
        n.lineWidth = 1
        pileLayer.addChild(n)
        pileNodes[key] = n
        return n
    }

    /// The pile's outline relative to the surface's top-left corner, split wherever a window in front hides it.
    private func pilePath(_ pile: Pile, on s: Surface) -> CGPath {
        let path = CGMutablePath()
        let h = pile.heights
        let b = Pile.bucket
        let base: CGFloat = 0
        let left: CGFloat = 0
        let snap = engine.snap
        let visible = h.indices.map { i in
            h[i] > 0.15 && !snap.isCovered(CGPoint(x: s.rect.minX + (CGFloat(i) + 0.5) * b, y: s.top + 1), behind: s)
        }
        var i = 0
        while i < h.count {
            guard visible[i] else { i += 1; continue }
            let start = i
            while i < h.count && visible[i] { i += 1 }
            let pts = (start..<i).map { CGPoint(x: left + (CGFloat($0) + 0.5) * b, y: base + h[$0]) }
            let x0 = left + CGFloat(start) * b, x1 = left + CGFloat(i) * b
            path.move(to: CGPoint(x: x0, y: base))
            path.addLine(to: CGPoint(x: x0, y: base + h[start] * 0.6))
            for k in 0..<(pts.count - 1) {
                let mid = CGPoint(x: (pts[k].x + pts[k + 1].x) / 2, y: (pts[k].y + pts[k + 1].y) / 2)
                path.addQuadCurve(to: mid, control: pts[k])
            }
            path.addLine(to: pts[pts.count - 1])
            path.addLine(to: CGPoint(x: x1, y: base + h[i - 1] * 0.6))
            path.addLine(to: CGPoint(x: x1, y: base))
            path.closeSubpath()
        }
        return path
    }
}
