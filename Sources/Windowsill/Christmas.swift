import SpriteKit
import AppKit

enum DragKind { case tree, snowman, present }

struct DragState {
    let id: UUID
    let kind: DragKind
    let grab: CGVector
    let start: CGPoint
    var moved = false
}

protocol Visitor: AnyObject {
    var node: SKNode { get }
    /// Returns false once the visitor has left the screen.
    func update(_ dt: CGFloat, in scene: WeatherScene) -> Bool
    func clicked(in scene: WeatherScene)
}

// MARK: - Tree

final class TreeNode: SKNode {
    private var shown: [Ornament] = []
    private let ornamentLayer = SKNode()

    override init() {
        super.init()
        let tree = SKSpriteNode(texture: Art.tree, size: TreeShape.size)
        tree.anchorPoint = CGPoint(x: 0.5, y: 0)
        addChild(tree)
        ornamentLayer.zPosition = 1
        addChild(ornamentLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ ornaments: [Ornament]) {
        guard ornaments != shown else { return }
        shown = ornaments
        ornamentLayer.removeAllChildren()
        for o in ornaments { ornamentLayer.addChild(Self.make(o)) }
    }

    /// Index of the ornament closest to a tree-local point, if one is within reach.
    func ornament(near p: CGPoint) -> Int? {
        let d = shown.indices.map { hypot(shown[$0].x - p.x, shown[$0].y - p.y) }
        guard let i = d.indices.min(by: { d[$0] < d[$1] }), d[i] < 16 else { return nil }
        return i
    }

    static func make(_ o: Ornament) -> SKNode {
        switch o.kind {
        case .bauble:
            return hanging(Art.bauble(o.color), Art.baubleSize, at: CGPoint(x: o.x, y: o.y))
        case .star:
            let s = SKSpriteNode(texture: Art.star, size: Art.fit(Art.star, height: 34))
            s.position = CGPoint(x: 0, y: TreeShape.apex.y + 12)
            let glow = SKSpriteNode(texture: Art.glow, size: CGSize(width: 64, height: 64))
            glow.color = NSColor(calibratedRed: 1, green: 0.85, blue: 0.35, alpha: 1)
            glow.colorBlendFactor = 1
            glow.blendMode = .add
            glow.zPosition = -1
            glow.alpha = 0.6
            s.addChild(glow)
            glow.run(.repeatForever(.sequence([.fadeAlpha(to: 0.25, duration: 1.1), .fadeAlpha(to: 0.7, duration: 1.1)])))
            return s
        case .cane:
            return hanging(Art.cane, Art.fit(Art.cane, height: 22), at: CGPoint(x: o.x, y: o.y))
        case .lights:
            let n = SKNode()
            n.position = CGPoint(x: o.x, y: o.y)
            let a = CGPoint(x: -32, y: 4), c = CGPoint(x: 0, y: -14), b = CGPoint(x: 32, y: 4)
            let wire = CGMutablePath()
            wire.move(to: a)
            wire.addQuadCurve(to: b, control: c)
            let line = SKShapeNode(path: wire)
            line.strokeColor = NSColor(calibratedWhite: 0.1, alpha: 0.8)
            line.lineWidth = 1
            n.addChild(line)
            let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .systemPink]
            for k in 0..<7 {
                let t = (CGFloat(k) + 0.5) / 7, u = 1 - t
                let p = CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                                y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
                let bulb = SKSpriteNode(texture: Art.glow, size: CGSize(width: 11, height: 11))
                bulb.color = colors[(k + o.color) % colors.count]
                bulb.colorBlendFactor = 1
                bulb.blendMode = .add
                bulb.position = p
                let core = SKSpriteNode(texture: Art.flake, size: CGSize(width: 4, height: 4))
                core.color = bulb.color
                core.colorBlendFactor = 0.6
                bulb.addChild(core)
                n.addChild(bulb)
                let on = Double.random(in: 0.3...0.9), off = Double.random(in: 0.2...0.7)
                bulb.run(.repeatForever(.sequence([.fadeAlpha(to: 0.3, duration: off), .fadeAlpha(to: 1, duration: on)])))
            }
            return n
        }
    }

    /// An ornament centred on `p`, hung from its top so it swings on its hook.
    private static func hanging(_ t: SKTexture, _ size: CGSize, at p: CGPoint) -> SKNode {
        let s = SKSpriteNode(texture: t, size: size)
        s.anchorPoint = CGPoint(x: 0.5, y: 1)
        s.position = CGPoint(x: p.x, y: p.y + size.height / 2)
        sway(s, by: 0.12, period: .random(in: 1.8...2.6))
        return s
    }
}

// MARK: - Decorations in the scene

extension WeatherScene {
    func updateDecor(_ dt: CGFloat) {
        let show = engine.state.showDecor
        decorLayer.isHidden = !show
        visitorLayer.isHidden = !show
        let d = engine.decor
        let rect = screenRect
        func mine(_ x: CGFloat, _ y: CGFloat) -> Bool { rect.contains(CGPoint(x: x, y: y + 1)) }

        var seen = Set<UUID>()
        for t in d.trees where mine(t.x, t.y) {
            seen.insert(t.id)
            let n = treeNodes[t.id] ?? makeTree(t.id)
            n.position = local(CGPoint(x: t.x, y: t.y))
            n.show(t.ornaments)
        }
        for s in d.snowmen where mine(s.x, s.y) {
            seen.insert(s.id)
            (snowmanNodes[s.id] ?? makeSnowman(s.id)).position = local(CGPoint(x: s.x, y: s.y))
        }
        for g in d.presents where mine(g.x, g.y) {
            seen.insert(g.id)
            (presentNodes[g.id] ?? makePresent(g)).position = local(CGPoint(x: g.x, y: g.y))
        }
        for (id, n) in treeNodes where !seen.contains(id) { n.removeFromParent(); treeNodes[id] = nil }
        for (id, n) in snowmanNodes where !seen.contains(id) { n.removeFromParent(); snowmanNodes[id] = nil }
        for (id, n) in presentNodes where !seen.contains(id) { n.removeFromParent(); presentNodes[id] = nil }

        visitors = visitors.filter { v in
            let alive = v.update(dt, in: self)
            if !alive { v.node.removeFromParent() }
            return alive
        }
    }

    private func makeTree(_ id: UUID) -> TreeNode {
        let n = TreeNode()
        decorLayer.addChild(n)
        treeNodes[id] = n
        if engine.state.freshIds.remove(id) != nil {
            n.setScale(0.05)
            let grow = SKAction.scale(to: 1.08, duration: 1.4)
            grow.timingMode = .easeOut
            n.run(.sequence([grow, .scale(to: 1, duration: 0.25)]))
        }
        return n
    }

    private func makeSnowman(_ id: UUID) -> SKNode {
        let n = SKNode()
        let body = SKSpriteNode(texture: Art.snowman, size: Art.snowmanSize)
        body.anchorPoint = CGPoint(x: 0.5, y: 0)
        sway(body, by: 0.03, period: .random(in: 2.8...3.6))
        n.addChild(body)
        decorLayer.addChild(n)
        snowmanNodes[id] = n
        if engine.state.freshIds.remove(id) != nil {
            // Rolled in as a growing snowball, then it pops up into a snowman.
            body.alpha = 0
            let ball = SKSpriteNode(texture: Art.snowball, size: CGSize(width: 30, height: 30))
            ball.position = CGPoint(x: -240, y: 6)
            ball.setScale(0.4)
            n.addChild(ball)
            let roll = SKAction.group([.moveTo(x: 0, duration: 2), .moveTo(y: 21, duration: 2),
                                       .scale(to: 1.4, duration: 2), .rotate(byAngle: -12, duration: 2)])
            roll.timingMode = .easeOut
            ball.run(.sequence([roll, .removeFromParent()]))
            body.setScale(0.2)
            body.run(.sequence([.wait(forDuration: 2), .group([.fadeIn(withDuration: 0.1), .scale(to: 1.12, duration: 0.18)]),
                                .scale(to: 1, duration: 0.12)]))
        }
        return n
    }

    private func makePresent(_ g: PresentItem) -> SKNode {
        let n = SKSpriteNode(texture: Art.present(Int(g.id.uuid.0)), size: Art.presentSize)
        n.anchorPoint = CGPoint(x: 0.5, y: 0)
        decorLayer.addChild(n)
        presentNodes[g.id] = n
        if engine.state.freshIds.remove(g.id) != nil {
            n.setScale(0)
            n.run(.sequence([.scale(to: 1.2, duration: 0.2), .scale(to: 1, duration: 0.1)]))
        }
        return n
    }

    // MARK: Pointer

    enum Hit {
        case visitor(Visitor)
        case present(UUID)
        case snowman(UUID)
        case tree(UUID, CGPoint)
    }

    func hit(_ p: CGPoint) -> Hit? {
        guard engine.state.showDecor else { return nil }
        for v in visitors.reversed() where v.node.calculateAccumulatedFrame().insetBy(dx: -8, dy: -8).contains(p) {
            return .visitor(v)
        }
        for (id, n) in presentNodes where n.calculateAccumulatedFrame().insetBy(dx: -4, dy: -4).contains(p) {
            return .present(id)
        }
        for (id, n) in snowmanNodes where n.calculateAccumulatedFrame().contains(p) { return .snowman(id) }
        for (id, n) in treeNodes {
            let l = n.convert(p, from: self)
            let trunk = abs(l.x) < 12 && l.y >= 0 && l.y <= 24
            let star = abs(l.x) < 18 && l.y > 195 && l.y < 230
            if TreeShape.contains(l) || trunk || star { return .tree(id, l) }
        }
        return nil
    }

    /// The overlay accepts clicks only while the pointer is over something of ours.
    func wantsMouse(at p: CGPoint) -> Bool { drag != nil || hit(p) != nil }

    override func mouseDown(with event: NSEvent) {
        let p = event.location(in: self)
        guard let h = hit(p) else { return }
        let tool = engine.state.tool
        switch h {
        case .visitor(let v):
            v.clicked(in: self)
        case .present(let id):
            if tool == .remove { poof(at: p); engine.remove(id) } else { startDrag(id, .present, p, presentNodes[id]) }
        case .snowman(let id):
            if tool == .remove { poof(at: p); engine.remove(id) } else { startDrag(id, .snowman, p, snowmanNodes[id]) }
        case .tree(let id, let l):
            switch tool {
            case .move:
                startDrag(id, .tree, p, treeNodes[id])
            case .remove:
                if let i = treeNodes[id]?.ornament(near: l) {
                    engine.removeOrnament(at: i, from: id)
                } else {
                    poof(at: p)
                    engine.remove(id)
                }
            case .bauble, .lights, .cane, .star:
                guard let kind = tool.ornament, kind == .star || TreeShape.contains(l) else { return }
                let o = Ornament(kind: kind, x: l.x, y: l.y, color: .random(in: 0..<Ornament.palette.count))
                engine.addOrnament(o, to: id)
            }
        }
    }

    private func startDrag(_ id: UUID, _ kind: DragKind, _ p: CGPoint, _ node: SKNode?) {
        guard let node else { return }
        drag = DragState(id: id, kind: kind, grab: CGVector(dx: p.x - node.position.x, dy: p.y - node.position.y), start: p)
        engine.beginDrag(id)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var d = drag else { return }
        let p = event.location(in: self)
        if hypot(p.x - d.start.x, p.y - d.start.y) > 3 { d.moved = true }
        let x = min(max(p.x - d.grab.dx, 10), size.width - 10)
        let y = min(max(p.y - d.grab.dy, 0), size.height - 40)
        if d.moved { engine.drag(d.id, to: global(CGPoint(x: x, y: y))) }
        drag = d
    }

    override func mouseUp(with event: NSEvent) {
        guard let d = drag else { return }
        drag = nil
        engine.endDrag()
        if d.kind == .present && !d.moved, let n = presentNodes[d.id] {
            confetti(at: CGPoint(x: n.position.x, y: n.position.y + 15))
            engine.openPresent(d.id)
        }
    }

    // MARK: Effects

    func poof(at p: CGPoint) {
        for _ in 0..<14 {
            let a = CGFloat.random(in: 0...(2 * .pi)), s = CGFloat.random(in: 40...120)
            emit(Art.flake, at: p, v: CGVector(dx: cos(a) * s, dy: sin(a) * s), life: 0.6,
                 size: CGSize(width: 6, height: 6), color: .white, layer: visitorLayer)
        }
    }

    func confetti(at p: CGPoint) {
        for _ in 0..<44 {
            emit(Art.square, at: p, v: CGVector(dx: .random(in: -170...170), dy: .random(in: 160...430)),
                 life: .random(in: 1.0...1.6), size: CGSize(width: 6, height: 3.5),
                 color: Ornament.palette.randomElement()!, gravity: 520, spin: .random(in: -12...12), layer: visitorLayer)
        }
    }

    func say(_ text: String, at p: CGPoint, in parent: SKNode) {
        let label = SKLabelNode(fontNamed: "HelveticaNeue-Bold")
        label.text = text
        label.fontSize = 15
        label.fontColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        label.verticalAlignmentMode = .center
        let w = label.frame.width + 22
        let bubble = SKShapeNode(rect: CGRect(x: -w / 2, y: -14, width: w, height: 28), cornerRadius: 14)
        bubble.fillColor = .white
        bubble.strokeColor = NSColor(calibratedWhite: 0.8, alpha: 1)
        bubble.addChild(label)
        bubble.position = p
        bubble.zPosition = 5
        parent.addChild(bubble)
        bubble.setScale(0.3)
        bubble.run(.sequence([.scale(to: 1, duration: 0.15), .wait(forDuration: 1.3), .fadeOut(withDuration: 0.3),
                              .removeFromParent()]))
    }

    // MARK: Visitors

    /// Local y that trees, the train and the Yeti stand on: the top of the Dock when it runs along
    /// the bottom of this screen, otherwise the bottom edge.
    var floorY: CGFloat {
        guard let dock = engine.snap.dock, dock.intersects(screenRect) else { return 0 }
        return dock.maxY - screenRect.minY
    }

    func callSanta() {
        guard !visitors.contains(where: { $0 is SantaVisit }) else { return }
        visitors.append(SantaVisit(scene: self))
    }

    func sendTrain() {
        guard !visitors.contains(where: { $0 is TrainVisit }) else { return }
        visitors.append(TrainVisit(scene: self))
    }

    func summonYeti() {
        guard !visitors.contains(where: { $0 is YetiVisit }) else { return }
        visitors.append(YetiVisit(scene: self))
    }
}

// MARK: - Santa

final class SantaVisit: Visitor {
    let node = SKNode()
    private var x: CGFloat
    private let baseY: CGFloat
    private var t: CGFloat = 0
    private var trail: CGFloat = 0
    private let dropX: CGFloat
    private var dropped = false
    private var deer: [SKSpriteNode] = []
    private let sleigh = SKSpriteNode(texture: Art.sleigh, size: Art.sleighSize)
    private static let pitch = Art.deerSizes[0].width * 0.85
    private static let sleighX = 2 * pitch + Art.deerSizes[0].width / 2 + 18 + Art.sleighSize.width / 2

    init(scene: WeatherScene) {
        x = scene.size.width + 60
        baseY = scene.size.height * .random(in: 0.62...0.8)
        dropX = scene.size.width * .random(in: 0.25...0.75)
        let sleighX = Self.sleighX
        let line = CGMutablePath()
        line.move(to: CGPoint(x: 10, y: 6))
        line.addLine(to: CGPoint(x: sleighX - Art.sleighSize.width * 0.3, y: -4))
        let reins = SKShapeNode(path: line)
        reins.strokeColor = NSColor(calibratedRed: 0.55, green: 0.12, blue: 0.1, alpha: 1)
        reins.lineWidth = 1.5
        node.addChild(reins)
        for k in 0..<3 {
            let d = SKSpriteNode(texture: Art.deer[0], size: Art.deerSizes[0])
            d.position = CGPoint(x: CGFloat(k) * Self.pitch, y: 0)
            d.zPosition = 1
            node.addChild(d)
            deer.append(d)
        }
        sleigh.position = CGPoint(x: sleighX, y: -6)
        sleigh.zPosition = 1
        node.addChild(sleigh)
        node.position = CGPoint(x: x, y: baseY)
        scene.visitorLayer.addChild(node)
    }

    func update(_ dt: CGFloat, in scene: WeatherScene) -> Bool {
        t += dt
        x -= 230 * dt
        node.position = CGPoint(x: x, y: baseY + sin(t * 2.2) * 10)
        // Each reindeer gallops on two frames, a step out of phase with the one ahead of it.
        for (k, d) in deer.enumerated() {
            let f = (Int(t * 7) + k) % 2
            d.texture = Art.deer[f]
            d.size = Art.deerSizes[f]
            d.position.y = (k % 2 == 0 ? 0 : 6) + (f == 0 ? 3 : -2)
        }
        sleigh.zRotation = sin(t * 2.2 + 0.8) * 0.06
        let sleighX = Self.sleighX
        trail += dt
        while trail > 0.025 {
            trail -= 0.025
            let tail = CGPoint(x: node.position.x + sleighX + Art.sleighSize.width / 2, y: node.position.y + .random(in: -16...4))
            scene.emit(Art.glow, at: tail, v: CGVector(dx: .random(in: -10...40), dy: .random(in: -30...5)),
                       life: .random(in: 0.6...1.1), size: CGSize(width: 7, height: 7),
                       color: Bool.random() ? .white : NSColor(calibratedRed: 1, green: 0.85, blue: 0.4, alpha: 1),
                       additive: true, layer: scene.visitorLayer)
        }
        if !dropped, x + sleighX < dropX {
            dropped = true
            drop(scene)
        }
        return x > -(sleighX + Art.sleighSize.width)
    }

    private func drop(_ scene: WeatherScene) {
        scene.engine.addPresent(at: scene.global(CGPoint(x: node.position.x + Self.sleighX, y: node.position.y - 30)),
                                anchored: false)
    }

    func clicked(in scene: WeatherScene) {
        scene.say("Ho ho ho!", at: CGPoint(x: Self.sleighX, y: Art.sleighSize.height / 2 + 30), in: node)
        drop(scene)
    }
}

// MARK: - Yeti

final class YetiVisit: Visitor {
    private enum Mode { case walk, jumpUp, carry, scared }
    let node = SKNode()
    private let body = SKSpriteNode(texture: Art.yeti[0], size: Art.yetiSize)
    private var pos: CGPoint
    private var dir: CGFloat = -1
    private var target: UUID?
    private var mode = Mode.walk
    private var t: CGFloat = 0
    private var hop: (from: CGPoint, to: CGPoint, t: CGFloat)?
    private var carried: SKSpriteNode?
    private var speed: CGFloat = 110
    private let width: CGFloat
    private let floor: CGFloat

    init(scene: WeatherScene) {
        width = scene.size.width
        floor = scene.floorY
        pos = CGPoint(x: scene.size.width + 50, y: floor)
        let rect = scene.screenRect
        target = scene.engine.decor.snowmen
            .filter { rect.contains(CGPoint(x: $0.x, y: $0.y + 1)) }
            .max { $0.x < $1.x }?.id
        body.anchorPoint = CGPoint(x: 0.5, y: 0)
        node.addChild(body)
        node.position = pos
        scene.visitorLayer.addChild(node)
    }

    func update(_ dt: CGFloat, in scene: WeatherScene) -> Bool {
        t += dt
        if let h = hop {
            let k = min(1, h.t + dt / 0.7)
            pos = CGPoint(x: h.from.x + (h.to.x - h.from.x) * k,
                          y: h.from.y + (h.to.y - h.from.y) * k + sin(k * .pi) * 60)
            hop = k >= 1 ? nil : (from: h.from, to: h.to, t: k)
            if k >= 1, mode == .jumpUp { grab(scene) }
        } else {
            switch mode {
            case .walk:
                if let id = target, let man = scene.engine.decor.snowmen.first(where: { $0.id == id }) {
                    let goal = scene.local(CGPoint(x: man.x, y: man.y))
                    let standX = goal.x + 34
                    if pos.x - standX > 2 {
                        pos.x -= speed * dt
                    } else if goal.y > pos.y + 4 {
                        hop = (from: pos, to: CGPoint(x: standX, y: goal.y), t: 0)
                        mode = .jumpUp
                    } else {
                        grab(scene)
                    }
                } else {
                    target = nil
                    pos.x -= speed * dt
                }
            case .carry, .scared:
                if pos.y > floor + 0.5 {
                    hop = (from: pos, to: CGPoint(x: pos.x + dir * 90, y: floor), t: 0)
                } else {
                    pos.x += dir * speed * dt
                }
            case .jumpUp:
                break
            }
        }
        node.position = pos
        node.xScale = dir < 0 ? 1 : -1
        let frame = hop == nil ? Int(t * 6) % 2 : 0
        body.texture = carried == nil ? Art.yeti[frame] : Art.yetiCarry[frame]
        body.size = carried == nil ? Art.yetiSizes[frame] : Art.yetiCarrySizes[frame]
        return pos.x > -120 && pos.x < width + 140
    }

    private func grab(_ scene: WeatherScene) {
        mode = .carry
        dir = -1
        speed = 150
        guard let id = target, scene.engine.take(id) != nil else { return }
        let man = SKSpriteNode(texture: Art.snowman, size: Art.snowmanSize)
        man.anchorPoint = CGPoint(x: 0.5, y: 0)
        // Held up in both raised fists.
        man.setScale(0.7)
        man.zRotation = 0.08
        man.position = CGPoint(x: 0, y: Art.yetiCarrySizes[0].height - 14)
        man.zPosition = -1          // behind the fists, so it reads as held (sibling order is ignored)
        node.addChild(man)
        carried = man
        scene.say("Mine!", at: CGPoint(x: 0, y: Art.yetiCarrySizes[0].height + Art.snowmanSize.height * 0.7), in: node)
    }

    func clicked(in scene: WeatherScene) {
        guard mode != .scared else { return }
        mode = .scared
        speed = 420
        dir = pos.x < width / 2 ? -1 : 1
        scene.say("Eek!", at: CGPoint(x: 0, y: Art.yetiSize.height + 18), in: node)
        if let man = carried {
            man.removeFromParent()
            carried = nil
            scene.engine.addSnowman(at: scene.global(CGPoint(x: pos.x, y: pos.y + 60)))
        }
    }
}

// MARK: - Gift train

final class TrainVisit: Visitor {
    let node = SKNode()
    private var x: CGFloat = 0
    private var stopX: CGFloat?
    private var treeId: UUID?
    private var waited: CGFloat = 0
    private var phase = 0             // 0 rolling in, 1 stopped at the tree, 2 leaving
    private var dropped = false
    private var smoke: CGFloat = 0
    private var wheels: [SKSpriteNode] = []
    private let loco = SKSpriteNode(texture: Art.locomotive, size: Art.locoSize)
    private var t: CGFloat = 0
    private let width: CGFloat
    private let floor: CGFloat
    private static let wagonW = Art.wagonSize.width, gap: CGFloat = 6, lift: CGFloat = 8
    private static let lx = 3 * (wagonW + gap)
    /// The funnel's top, measured on the painting: 69% along the engine, at its top edge.
    private static let chimney = CGPoint(x: lx + Art.locoSize.width * 0.69, y: lift + Art.locoSize.height - 2)

    init(scene: WeatherScene) {
        width = scene.size.width
        floor = scene.floorY
        let giftSize = CGSize(width: Art.presentSize.width * 0.8, height: Art.presentSize.height * 0.8)
        for k in 0..<3 {
            let cx = CGFloat(k) * (Self.wagonW + Self.gap)
            let wagon = SKSpriteNode(texture: Art.wagon, size: Art.wagonSize)
            wagon.anchorPoint = .zero
            wagon.position = CGPoint(x: cx, y: Self.lift)
            node.addChild(wagon)
            // Cargo sits inside the open wagon: drawn behind it, so the front panel hides its lower half.
            let rim = Self.lift + Art.wagonSize.height * 0.45
            for j in 0..<2 {
                let slot = CGPoint(x: cx + Self.wagonW * (j == 0 ? 0.3 : 0.7), y: rim)
                let cargo: SKSpriteNode
                if k == 0 && j == 1 {
                    cargo = SKSpriteNode(texture: Art.elf, size: Art.fit(Art.elf, height: 36))
                    sway(cargo, by: 0.07, period: 1.4)          // the elf rocks as it waves
                } else {
                    cargo = SKSpriteNode(texture: Art.present(k * 2 + j), size: giftSize)
                }
                cargo.anchorPoint = CGPoint(x: 0.5, y: 0)
                cargo.position = slot
                cargo.zPosition = -1
                node.addChild(cargo)
            }
            addWheels(at: [cx + Self.wagonW * 0.22, cx + Self.wagonW * 0.78], size: 18)
        }
        loco.anchorPoint = .zero
        loco.position = CGPoint(x: Self.lx, y: Self.lift)
        node.addChild(loco)
        // Along the engine's dark chassis strip (6%-78% of its width); the cowcatcher is past it.
        addWheels(at: [0.2, 0.44, 0.66].map { Self.lx + Art.locoSize.width * $0 }, size: 22)
        x = -(Self.lx + Art.locoSize.width) - 20

        let rect = scene.screenRect
        if let tree = scene.engine.decor.trees.filter({ rect.contains(CGPoint(x: $0.x, y: $0.y + 1)) })
            .min(by: { $0.x < $1.x }) {
            treeId = tree.id
            stopX = scene.local(CGPoint(x: tree.x, y: tree.y)).x - (Self.wagonW + Self.gap) - Self.wagonW / 2
        }
        node.position = CGPoint(x: x, y: floor)
        scene.visitorLayer.addChild(node)
    }

    private func addWheels(at xs: [CGFloat], size: CGFloat) {
        for wx in xs {
            let w = SKSpriteNode(texture: Art.wheel, size: CGSize(width: size, height: size))
            w.position = CGPoint(x: wx, y: size / 2)
            w.zPosition = 1
            node.addChild(w)
            wheels.append(w)
        }
    }

    func update(_ dt: CGFloat, in scene: WeatherScene) -> Bool {
        var v: CGFloat = 0
        switch phase {
        case 0:
            v = 150
            if let s = stopX {
                v = max(25, min(150, (s - x) * 1.6))
                if x >= s { phase = 1 }
            }
        case 1:
            waited += dt
            if waited > 0.8, !dropped { deliver(scene) }
            if waited > 2.4 { phase = 2 }
        default:
            v = min(170, 40 + (waited - 2.4) * 120)
            waited += dt
        }
        x += v * dt
        t += dt
        node.position = CGPoint(x: x, y: floor)
        for w in wheels { w.zRotation -= v * dt / (w.size.width / 2) }
        loco.position.y = Self.lift + abs(sin(t * 14)) * min(1, v / 150) * 1.5   // chuffs while it rolls
        smoke += dt
        let every: CGFloat = v > 1 ? 0.12 : 0.35
        while smoke > every {
            smoke -= every
            let c = CGPoint(x: x + Self.chimney.x, y: floor + Self.chimney.y)
            scene.emit(Art.glow, at: c, v: CGVector(dx: -30 + .random(in: -12...12), dy: .random(in: 40...65)),
                       life: 1.6, size: CGSize(width: 16, height: 16), color: NSColor(calibratedWhite: 0.88, alpha: 1),
                       grow: 2.2, layer: scene.visitorLayer)
        }
        return x < width + 40
    }

    private func deliver(_ scene: WeatherScene) {
        dropped = true
        guard let id = treeId, let tree = scene.engine.decor.trees.first(where: { $0.id == id }) else { return }
        scene.engine.addPresent(at: CGPoint(x: tree.x + .random(in: -42...42), y: tree.y), anchored: true)
    }

    func clicked(in scene: WeatherScene) {
        scene.say("Toot toot!", at: CGPoint(x: Self.chimney.x, y: 100), in: node)
    }
}
