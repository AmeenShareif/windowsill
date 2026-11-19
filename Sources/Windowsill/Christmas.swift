import SpriteKit
import AppKit

enum DragKind { case tree, snowman, present }

/// Depth inside the desk layer, front to back: effects, visitors, presents, snowmen, trees. With
/// children (a tree's ornaments, the train's wheels) it all stays below the hole layer's z of 8.
enum Depth {
    static let tree: CGFloat = 0, snowman: CGFloat = 2, present: CGFloat = 3, visitor: CGFloat = 4, effect: CGFloat = 5
}

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

    /// Shows the tree's ornaments. One just added pops on with a little spring, so a click visibly did something.
    func show(_ ornaments: [Ornament]) {
        guard ornaments != shown else { return }
        let added = ornaments.count == shown.count + 1 && Array(ornaments.prefix(shown.count)) == shown
        shown = ornaments
        ornamentLayer.removeAllChildren()
        for o in ornaments { ornamentLayer.addChild(Self.make(o)) }
        if added, let n = ornamentLayer.children.last {
            n.setScale(0.1)
            let out = SKAction.scale(to: 1.3, duration: 0.14)
            out.timingMode = .easeOut
            n.run(.sequence([out, .scale(to: 0.9, duration: 0.08), .scale(to: 1, duration: 0.08)]))
        }
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

/// A quick squash and stretch, for anything that lands. Scaled about the node's origin (its feet).
func squash(_ n: SKNode, by amount: CGFloat = 1) {
    guard n.action(forKey: "squash") == nil else { return }
    let down = SKAction.group([.scaleX(to: 1 + 0.14 * amount, duration: 0.07), .scaleY(to: 1 - 0.18 * amount, duration: 0.07)])
    let up = SKAction.group([.scaleX(to: 1 - 0.05 * amount, duration: 0.1), .scaleY(to: 1 + 0.07 * amount, duration: 0.1)])
    let settle = SKAction.scale(to: 1, duration: 0.12)
    up.timingMode = .easeOut
    settle.timingMode = .easeInEaseOut
    n.run(.sequence([down, up, settle]), withKey: "squash")
}

// MARK: - Decorations in the scene

extension WeatherScene {
    /// Trees, and snowmen and presents on the floor, stand on the desk behind your windows. Whatever
    /// rides a window, or is in your hand, is drawn in front, and hides when a window in front of the one
    /// it stands on covers it. What falls goes behind the windows: drawn in front, a snowman knocked off
    /// slid down the face of the window under it (CI, 2026-11-19).
    func updateDecor(_ dt: CGFloat) {
        let show = engine.state.showDecor
        deskLayer.isHidden = !show
        decorLayer.isHidden = !show
        visitorLayer.isHidden = !show
        let d = engine.decor
        let rect = screenRect
        let held = engine.draggingId
        let landed = engine.landed
        func mine(_ x: CGFloat, _ y: CGFloat) -> Bool { rect.contains(CGPoint(x: x, y: y + 1)) }
        func covered(_ window: Int?, _ x: CGFloat) -> Bool {
            guard let w = window, let s = surfaceByKey[w] else { return false }
            return engine.snap.isCovered(CGPoint(x: x, y: s.top + 1), behind: s)
        }

        var seen = Set<UUID>()
        for t in d.trees where mine(t.x, t.y) {
            seen.insert(t.id)
            let n = treeNodes[t.id] ?? makeTree(t.id)
            place(n, front: t.id == held)
            n.position = local(CGPoint(x: t.x, y: t.y))
            n.show(t.ornaments)
            if landed.contains(t.id) { squash(n, by: 0.6) }
        }
        for s in d.snowmen where mine(s.x, s.y) {
            seen.insert(s.id)
            let n = snowmanNodes[s.id] ?? makeSnowman(s.id)
            let loose = s.id == held || engine.isFalling(s.id)
            // Its feet behind a window in front, it goes onto the desk under the window holes: what stands
            // above that window still shows. Hidden whole, it blinked out in plain view (CI, 2026-11-18).
            place(n, front: s.id == held || (s.windowId != nil && !loose && !covered(s.windowId, s.x)))
            n.zPosition = depth(Depth.snowman, on: loose ? nil : s.windowId)
            n.position = local(CGPoint(x: s.x, y: s.y))
            tumble(n, falling: s.id != held && engine.isFalling(s.id), dt: dt, seed: s.id)
            if landed.contains(s.id) { squash(n) }
        }
        for g in d.presents where mine(g.x, g.y) {
            seen.insert(g.id)
            let n = presentNodes[g.id] ?? makePresent(g)
            let loose = g.id == held || engine.isFalling(g.id)
            place(n, front: g.id == held || (g.windowId != nil && !loose && !covered(g.windowId, g.x)))
            n.zPosition = depth(Depth.present, on: loose ? nil : g.windowId)
            n.position = local(CGPoint(x: g.x, y: g.y))
            tumble(n, falling: g.id != held && engine.isFalling(g.id), dt: dt, seed: g.id)
            if landed.contains(g.id) { squash(n, by: 1.3) }
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

    /// Something falling tips over as it goes, one way or the other, and stands back up once it lands.
    private func tumble(_ n: SKNode, falling: Bool, dt: CGFloat, seed: UUID) {
        let lean: CGFloat = falling ? (seed.uuid.0 & 1 == 0 ? 0.45 : -0.45) : 0
        n.zRotation += (lean - n.zRotation) * min(1, dt * (falling ? 3 : 14))
    }

    private func place(_ n: SKNode, front: Bool) {
        let layer = front ? decorLayer : deskLayer
        if n.parent !== layer { n.move(toParent: layer) }
    }

    /// Standing on a window, a thing takes that window's depth: everything on a window behind is drawn
    /// behind everything on the windows in front of it, and all of it under what is held or falling.
    /// Kept within -1.4...0.3 so it stays above the snow piled on the windows (decor 11 + z > pile 9).
    func depth(_ base: CGFloat, on window: Int?) -> CGFloat {
        guard let w = window, let order = surfaceByKey[w]?.order else { return base }
        return (base - CGFloat(min(order, 4)) * 4) * 0.1
    }

    private func makeTree(_ id: UUID) -> TreeNode {
        let n = TreeNode()
        deskLayer.addChild(n)
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
        n.zPosition = Depth.snowman
        deskLayer.addChild(n)
        snowmanNodes[id] = n
        if engine.state.freshIds.remove(id) != nil {
            // Its two snowballs were rolled from the snow and stacked here (SnowmanBuild); over them the
            // face, scarf and hat pop on.
            body.alpha = 0
            let pop = SKAction.sequence([.scale(to: 1.05, duration: 0.12), .scale(to: 1, duration: 0.1)])
            pop.timingMode = .easeOut
            body.run(.group([.fadeIn(withDuration: 0.2), pop]))
        }
        return n
    }

    private func makePresent(_ g: PresentItem) -> SKNode {
        let n = SKNode()
        let box = SKSpriteNode(texture: Art.present(Int(g.id.uuid.0)), size: Art.presentSize)
        box.anchorPoint = CGPoint(x: 0.5, y: 0)
        n.addChild(box)
        n.zPosition = Depth.present
        deskLayer.addChild(n)
        presentNodes[g.id] = n
        if engine.state.freshIds.remove(g.id) != nil {
            box.setScale(0)
            box.run(.sequence([.scale(to: 1.2, duration: 0.2), .scale(to: 1, duration: 0.1)]))
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

    /// What is under a scene point. Things on the desk cannot be reached through a window in front of them.
    func hit(_ p: CGPoint) -> Hit? {
        guard engine.state.showDecor else { return nil }
        let behindGlass = overWindow(p)
        func reachable(_ n: SKNode) -> Bool { !n.isHidden && !(behindGlass && n.parent === deskLayer) }
        for v in visitors.reversed() where reachable(v.node)
            && v.node.calculateAccumulatedFrame().insetBy(dx: -8, dy: -8).contains(p) {
            return .visitor(v)
        }
        for (id, n) in presentNodes where reachable(n) && n.calculateAccumulatedFrame().insetBy(dx: -4, dy: -4).contains(p) {
            return .present(id)
        }
        for (id, n) in snowmanNodes where reachable(n) && n.calculateAccumulatedFrame().contains(p) { return .snowman(id) }
        for (id, n) in treeNodes where reachable(n) {
            let l = n.convert(p, from: self)
            let trunk = abs(l.x) < 12 && l.y >= 0 && l.y <= 24
            let star = abs(l.x) < 18 && l.y > 195 && l.y < 230
            if TreeShape.contains(l) || trunk || star { return .tree(id, l) }
        }
        return nil
    }

    /// The overlay accepts clicks only while the pointer is over something of ours.
    func wantsMouse(at p: CGPoint) -> Bool { drag != nil || hit(p) != nil }

    override func mouseDown(with event: NSEvent) { pointerDown(event.location(in: self)) }
    override func mouseDragged(with event: NSEvent) { pointerDragged(event.location(in: self)) }
    override func mouseUp(with event: NSEvent) { pointerUp() }

    /// A press at a scene point, from the mouse or from the demo's scripted pointer.
    func pointerDown(_ p: CGPoint) {
        guard let h = hit(p) else { return }
        let tool = engine.state.tool
        switch h {
        case .visitor(let v):
            v.clicked(in: self)
        case .present(let id):
            if tool == .remove { poof(at: p, in: presentNodes[id]?.parent); engine.remove(id) }
            else { startDrag(id, .present, p, presentNodes[id]) }
        case .snowman(let id):
            if tool == .remove { poof(at: p, in: snowmanNodes[id]?.parent); engine.remove(id) }
            else { startDrag(id, .snowman, p, snowmanNodes[id]) }
        case .tree(let id, let l):
            switch tool {
            case .move:
                startDrag(id, .tree, p, treeNodes[id])
            case .remove:
                poof(at: p, in: treeNodes[id]?.parent)
                if let i = treeNodes[id]?.ornament(near: l) {
                    engine.removeOrnament(at: i, from: id)
                } else {
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

    func pointerDragged(_ p: CGPoint) {
        guard var d = drag else { return }
        if hypot(p.x - d.start.x, p.y - d.start.y) > 3 { d.moved = true }
        let x = min(max(p.x - d.grab.dx, 10), size.width - 10)
        // The scene ends at the menu bar: whatever is carried stops with its top just under it.
        let tall: CGFloat = d.kind == .tree ? TreeShape.apex.y + 30 : d.kind == .snowman ? Art.snowmanSize.height : Art.presentSize.height
        let y = min(max(p.y - d.grab.dy, 0), ceilingY - tall)
        if d.moved { engine.drag(d.id, to: global(CGPoint(x: x, y: y))) }
        drag = d
    }

    func pointerUp() {
        guard let d = drag else { return }
        drag = nil
        engine.endDrag()
        guard d.kind == .present && !d.moved, let n = presentNodes[d.id] else { return }
        // Opening a present hangs a bauble on the nearest tree: a spark carries it there.
        let from = CGPoint(x: n.position.x, y: n.position.y + 15)
        // Effects stay at the depth of what made them: a present on the desk throws its confetti behind
        // the windows in front of it, not across them.
        let layer = n.parent === deskLayer ? deskLayer : visitorLayer
        confetti(at: from, in: layer)
        engine.openPresent(d.id)
        let gift = global(n.position)
        guard let tree = engine.decor.trees.min(by: { hypot($0.x - gift.x, $0.y - gift.y) < hypot($1.x - gift.x, $1.y - gift.y) }),
              let o = tree.ornaments.last else { return }
        fly(Art.glow, from: from, to: local(CGPoint(x: tree.x + o.x, y: tree.y + o.y)), in: layer)
    }

    // MARK: Effects

    func poof(at p: CGPoint, in layer: SKNode? = nil) {
        for _ in 0..<14 {
            let a = CGFloat.random(in: 0...(2 * .pi)), s = CGFloat.random(in: 40...120)
            emit(Art.flake, at: p, v: CGVector(dx: cos(a) * s, dy: sin(a) * s), life: 0.6,
                 size: CGSize(width: 6, height: 6), color: .white, layer: layer === deskLayer ? deskLayer : visitorLayer)
        }
    }

    func confetti(at p: CGPoint, in layer: SKNode) {
        for _ in 0..<44 {
            emit(Art.square, at: p, v: CGVector(dx: .random(in: -170...170), dy: .random(in: 160...430)),
                 life: .random(in: 1.0...1.6), size: CGSize(width: 6, height: 3.5),
                 color: Ornament.palette.randomElement()!, gravity: 520, spin: .random(in: -12...12), layer: layer)
        }
    }

    /// A golden spark that arcs from one point to another.
    private func fly(_ t: SKTexture, from a: CGPoint, to b: CGPoint, in layer: SKNode) {
        let spark = SKSpriteNode(texture: t, size: CGSize(width: 22, height: 22))
        spark.color = NSColor(calibratedRed: 1, green: 0.85, blue: 0.4, alpha: 1)
        spark.colorBlendFactor = 1
        spark.blendMode = .add
        spark.position = a
        spark.zPosition = Depth.effect
        layer.addChild(spark)
        let path = CGMutablePath()
        path.move(to: a)
        path.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: max(a.y, b.y) + 120))
        let go = SKAction.follow(path, asOffset: false, orientToPath: false, duration: 0.55)
        go.timingMode = .easeInEaseOut
        spark.run(.sequence([go, .group([.scale(to: 2.2, duration: 0.2), .fadeOut(withDuration: 0.2)]), .removeFromParent()]))
    }

    func say(_ text: String, at p: CGPoint, in parent: SKNode) {
        let label = SKLabelNode(fontNamed: "HelveticaNeue-Bold")
        label.text = text
        label.fontSize = 15
        label.fontColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        label.verticalAlignmentMode = .center
        label.zPosition = 0.1   // siblings order is ignored: at equal z the text could draw under the bubble
        let w = label.frame.width + 22
        let bubble = SKShapeNode(rect: CGRect(x: -w / 2, y: -14, width: w, height: 28), cornerRadius: 14)
        bubble.fillColor = .white
        bubble.strokeColor = NSColor(calibratedWhite: 0.8, alpha: 1)
        bubble.addChild(label)
        bubble.setScale(0.3)
        // The holder undoes a mirrored speaker (a visitor walking right), and a speaker that turns round
        // mid-sentence flips it with him, so the words always read left to right.
        let holder = SKNode()
        holder.name = "bubble"
        // Just under the menu bar there may be no room above the speaker: say it a little lower.
        let over = convert(p, from: parent).y + 16 - ceilingY
        holder.position = over > 0 ? CGPoint(x: p.x, y: p.y - over) : p
        holder.zPosition = 2    // on the desk: 1 + Depth.visitor + 2 = 7, still under the window holes at 8
        holder.xScale = parent.xScale < 0 ? -1 : 1
        holder.addChild(bubble)
        parent.childNode(withName: "bubble")?.removeFromParent()   // one thought at a time
        parent.addChild(holder)
        bubble.run(.sequence([.scale(to: 1, duration: 0.15), .wait(forDuration: 1.3), .fadeOut(withDuration: 0.3)]))
        holder.run(.sequence([.wait(forDuration: 1.75), .removeFromParent()]))
    }

    // MARK: Visitors

    /// Local y that trees, the train and the Yeti stand on: this screen's floor surface (the top of
    /// the Dock when it runs along the bottom, otherwise the bottom edge), where fallen snow lies too.
    var floorY: CGFloat {
        let key = Surface.groundKey(screenIndex)
        return (engine.snap.surfaces.first { $0.key == key }?.top).map { $0 - screenRect.minY } ?? 0
    }

    /// Local y of the top of this screen's usable area: the overlay ends at the menu bar.
    var ceilingY: CGFloat { size.height }

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
        // High in the sky, but never up in the menu bar; over the tops of your windows when there is room,
        // else as high as it may go, not across their title bars (CI, 2026-11-18).
        let top = scene.ceilingY - Art.sleighSize.height - 20
        let tallest = scene.engine.snap.windows.filter { $0.frame.intersects(scene.screenRect) }
            .map { $0.frame.maxY - scene.screenRect.minY }.max() ?? 0
        let clear = tallest + Art.sleighSize.height / 2 + 24
        baseY = clear <= top ? .random(in: min(max(clear, scene.size.height * 0.62), top)...top) : top
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
        // Each reindeer gallops on a continuous stride: it rises and pitches as its legs gather, the
        // painted frame flips at the top and bottom of the stride, and each runs a beat behind the one ahead.
        for (k, d) in deer.enumerated() {
            let ph = t * 13 + CGFloat(k) * .pi * 0.5
            let f = sin(ph) >= 0 ? 0 : 1
            d.texture = Art.deer[f]
            d.size = Art.deerSizes[f]
            d.position.y = (k % 2 == 0 ? 0 : 6) + sin(ph) * 3.5
            d.zRotation = cos(ph) * 0.07
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
