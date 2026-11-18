import SpriteKit
import AppKit

/// Something standing where the train runs: its span along the floor in local x, and a tree's id.
typealias TrackItem = (lo: CGFloat, hi: CGFloat, tree: UUID?)

extension WeatherScene {
    /// Everything standing on this screen's floor or Dock, where the train runs: trees, snowmen,
    /// presents, and snowmen being rolled there. Not what is held or still falling.
    func trackItems() -> [TrackItem] {
        let d = engine.decor, floor = floorY, rect = screenRect, held = engine.draggingId
        var items: [TrackItem] = []
        func put(_ id: UUID, _ x: CGFloat, _ y: CGFloat, _ window: Int?, half: CGFloat, tree: UUID? = nil) {
            guard window == nil, id != held, !engine.isFalling(id), rect.contains(CGPoint(x: x, y: y + 1)) else { return }
            let p = local(CGPoint(x: x, y: y))
            if abs(p.y - floor) <= 4 { items.append((p.x - half, p.x + half, tree)) }
        }
        for t in d.trees { put(t.id, t.x, t.y, nil, half: 70, tree: t.id) }
        for m in d.snowmen { put(m.id, m.x, m.y, m.windowId, half: SnowmanBuild.footprint) }
        for g in d.presents { put(g.id, g.x, g.y, g.windowId, half: Art.presentSize.width / 2) }
        for case let b as SnowmanBuild in visitors where b.key < 0 {
            guard let s = surfaceByKey[b.key] else { continue }
            let x0 = s.rect.minX - screenRect.minX
            items.append((x0 + b.claim.lowerBound, x0 + b.claim.upperBound, nil))
        }
        return items
    }
}

// MARK: - Gift train

/// The gift train runs along the floor and the Dock, behind your windows. It never drives through
/// anything: it stops short of the first tree, snowman or present on its track, the elf throws a present
/// from there to land under the tree, and it backs out the way it came. Its cowcatcher plows the snow.
final class TrainVisit: Visitor {
    private enum Phase { case arriving, stopped, backing, vanishing }
    let node = SKNode()
    private let dir: CGFloat               // +1 comes in from the left; the paintings face right
    private var rear: CGFloat              // local x of the end of the last wagon
    private var v: CGFloat = 150           // along `dir`; below zero it is backing
    private var phase = Phase.arriving
    private var t: CGFloat = 0, waited: CGFloat = 0, stuck: CGFloat = 0, smoke: CGFloat = 0
    private var floor: CGFloat
    private let width: CGFloat
    private let gift = PresentItem(x: 0, y: 0, anchored: true)
    private var giftBox: SKSpriteNode?     // in the last wagon until the elf throws it
    private var elf: SKSpriteNode?
    private var plowed: Int?               // the last bucket of snow the cowcatcher cleared
    private var plowMass: CGFloat = 0, plowClock: CGFloat = 0
    private var wheels: [SKSpriteNode] = []
    private let loco = SKSpriteNode(texture: Art.locomotive, size: Art.locoSize)
    private static let wagonW = Art.wagonSize.width, gap: CGFloat = 6, lift: CGFloat = 8
    private static let lx = 3 * (wagonW + gap)
    private static let length = lx + Art.locoSize.width
    /// It stops this far short of whatever is on the track.
    private static let margin: CGFloat = 12
    /// The funnel's top, measured on the painting: 69% along the engine, at its top edge.
    private static let chimney = CGPoint(x: lx + Art.locoSize.width * 0.69, y: lift + Art.locoSize.height - 2)
    /// The present it brings rides in the last wagon, beside the elf who throws it.
    private static let giftSlot = CGPoint(x: 2 * (wagonW + gap) + wagonW * 0.7, y: lift + Art.wagonSize.height * 0.7)

    private var front: CGFloat { rear + dir * Self.length }
    /// Local xs the train covers.
    var span: ClosedRange<CGFloat> { min(rear, front)...max(rear, front) }

    init(scene: WeatherScene) {
        let w = scene.size.width
        width = w
        floor = scene.floorY
        let items = scene.trackItems()
        let fromLeft = Self.cost(1, items, w), fromRight = Self.cost(-1, items, w)
        dir = fromLeft == fromRight ? (Bool.random() ? 1 : -1) : (fromLeft < fromRight ? 1 : -1)
        rear = dir > 0 ? -20 - Self.length : width + 20 + Self.length
        let cargoSize = CGSize(width: Art.presentSize.width * 0.8, height: Art.presentSize.height * 0.8)
        for k in 0..<3 {
            let cx = CGFloat(k) * (Self.wagonW + Self.gap)
            let wagon = SKSpriteNode(texture: Art.wagon, size: Art.wagonSize)
            wagon.anchorPoint = .zero
            wagon.position = CGPoint(x: cx, y: Self.lift)
            node.addChild(wagon)
            // Cargo sits inside the open wagon: drawn behind it, so the front panel hides its lower half.
            let rim = Self.lift + Art.wagonSize.height * 0.7     // CI shot: at 0.45 the gifts hid completely
            for j in 0..<2 {
                let cargo: SKSpriteNode
                if k == 2 && j == 0 {
                    cargo = SKSpriteNode(texture: Art.elf, size: Art.fit(Art.elf, height: 36))
                    sway(cargo, by: 0.07, period: 1.4)          // the elf rocks as it waves
                    elf = cargo
                } else {
                    cargo = SKSpriteNode(texture: Art.present(k == 2 ? Int(gift.id.uuid.0) : k * 2 + j), size: cargoSize)
                    if k == 2 { giftBox = cargo }
                }
                cargo.anchorPoint = CGPoint(x: 0.5, y: 0)
                cargo.position = CGPoint(x: cx + Self.wagonW * (j == 0 ? 0.3 : 0.7), y: rim)
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
        node.xScale = dir
        node.position = CGPoint(x: rear, y: floor)
        node.zPosition = Depth.visitor
        scene.deskLayer.addChild(node)
    }

    /// What coming in from side `d` (+1 the left) costs: nothing when the first thing on the track is a
    /// tree to leave the present under, more the farther the elf must throw it over something else, and
    /// most where something stands so near the edge that the engine could not come into view.
    private static func cost(_ d: CGFloat, _ items: [TrackItem], _ width: CGFloat) -> CGFloat {
        let near = items.sorted { d > 0 ? $0.lo < $1.lo : $0.hi > $1.hi }
        guard let first = near.first else { return 4 }
        let stop = d > 0 ? first.lo - margin : first.hi + margin
        var cost: CGFloat = 4
        if let tree = near.first(where: { $0.tree != nil }) {
            cost = tree.tree == first.tree ? 0 : 1 + abs((tree.lo + tree.hi) / 2 - stop) / width
        }
        return (d > 0 ? stop : width - stop) < Art.locoSize.width ? cost + 10 : cost
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
        t += dt
        floor = scene.floorY
        let items = scene.trackItems()
        switch phase {
        case .arriving:
            let room = clearance(items, back: false) - Self.margin
            if room <= 0.5 {
                v = 0
                phase = .stopped
            } else {
                v = min(v + 260 * dt, max(25, min(150, room * 1.6)))     // brakes as it nears what is ahead
                rear += dir * min(v * dt, room)
            }
        case .stopped:
            waited += dt
            if waited > 0.5 && giftBox != nil { throwGift(scene) }
            if waited > 1.7 { phase = .backing }
        case .backing:
            let room = clearance(items, back: true) - Self.margin
            if room <= 0.5 {
                v = 0
                stuck += dt
                if stuck > 2 { vanish(scene) }
            } else {
                stuck = 0
                v = max(v - 120 * dt, -max(25, min(140, room * 1.6)))
                rear += dir * max(v * dt, -room)
            }
        case .vanishing:
            waited += dt
            if waited > 0.5 { return false }
        }
        plow(dt, scene)
        animate(dt, scene)
        // Gone once it has backed off the side it came in from, or run off the far side with nothing in its way.
        if phase == .backing && (front - (dir > 0 ? -20 : width + 20)) * dir < 0 { return false }
        if phase == .arriving && (rear - (dir > 0 ? width + 20 : -20)) * dir > 0 { return false }
        return true
    }

    /// How far it can roll before its front (backing, its rear) reaches the next thing on the track.
    /// Something set down on the train itself is not in its way.
    private func clearance(_ items: [TrackItem], back: Bool) -> CGFloat {
        let edge = back ? rear : front, s = back ? -dir : dir
        return items.compactMap { i -> CGFloat? in
            let gap = s > 0 ? i.lo - edge : edge - i.hi
            return gap >= -2 ? max(0, gap) : nil
        }.min() ?? .infinity
    }

    /// The elf throws the present in a high arc to the near side of the closest tree, clear of the
    /// presents already there. With no tree on the track (or no room for another present) it just toots.
    private func throwGift(_ scene: WeatherScene) {
        guard let box = giftBox else { return }
        giftBox = nil
        let from = CGPoint(x: rear + dir * Self.giftSlot.x, y: floor + Self.giftSlot.y)
        let trees = scene.trackItems().compactMap { $0.tree == nil ? nil : ($0.lo + $0.hi) / 2 }
        guard let tx = trees.min(by: { abs($0 - from.x) < abs($1 - from.x) }), scene.engine.decor.presents.count < 8 else {
            scene.say("Toot toot!", at: CGPoint(x: Self.chimney.x, y: 100), in: node)
            return
        }
        let side: CGFloat = from.x < tx ? -1 : 1
        let under = scene.engine.decor.presents.filter { $0.windowId == nil }.map { scene.local(CGPoint(x: $0.x, y: $0.y)).x }
        let spots = [34, 56, 14].map { tx + side * $0 }
        let to = spots.first { s in under.allSatisfy { abs($0 - s) > 20 } } ?? spots[0]
        elf?.run(.sequence([.moveBy(x: 0, y: 8, duration: 0.1), .moveBy(x: 0, y: -8, duration: 0.16)]))

        box.move(toParent: scene.deskLayer)
        box.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        box.xScale = 1
        box.zPosition = Depth.effect
        box.position = CGPoint(x: from.x, y: from.y + box.size.height / 2)
        let end = CGPoint(x: to, y: floor + Art.presentSize.height / 2)
        let dist = abs(end.x - box.position.x)
        let path = CGMutablePath()
        path.move(to: box.position)
        path.addQuadCurve(to: end, control: CGPoint(x: (box.position.x + end.x) / 2,
                                                    y: max(box.position.y, end.y) + 2 * (60 + 0.35 * dist)))
        let dur = 0.45 + dist / 500
        var g = gift
        let at = scene.global(CGPoint(x: to, y: floor))
        g.x = at.x
        g.y = at.y
        // It lands as a present of its own: the scene draws it from then on, and this box goes. The train
        // may be gone by then, so nothing here depends on it.
        let landed = SKAction.run { [weak scene, weak box] in
            guard let scene, let box else { return }
            guard scene.engine.add(g, pop: false) else {
                scene.poof(at: box.position, in: scene.deskLayer)
                box.removeFromParent()
                return
            }
            box.run(.sequence([.wait(forDuration: 0.02), .run { [weak scene, weak box] in
                if let n = scene?.presentNodes[g.id] { squash(n, by: 1.3) }
                box?.removeFromParent()
            }]))
        }
        box.run(.sequence([.group([.follow(path, asOffset: false, orientToPath: false, duration: dur),
                                   .scale(to: 1.25, duration: dur), .rotate(byAngle: -dir * 2 * .pi, duration: dur)]),
                           .rotate(toAngle: 0, duration: 0), landed]))
    }

    /// The cowcatcher (backing, the last wagon) clears the snow it runs over and throws it on ahead.
    private func plow(_ dt: CGFloat, _ scene: WeatherScene) {
        plowClock += dt
        guard abs(v) > 1 else {
            plowed = nil
            return
        }
        let lead = v > 0 ? front + dir * 2 : rear - dir * 2
        let gx = scene.global(CGPoint(x: lead, y: floor)).x
        let i = Int((gx / Pile.bucket).rounded(.down))
        if let last = plowed, last != i {
            let step = i > last ? 1 : -1
            var j = last
            while j != i {
                j += step
                plowMass += clear(at: (CGFloat(j) + 0.5) * Pile.bucket, scene)
            }
        } else if plowed == nil {
            plowMass += clear(at: gx, scene)
        }
        plowed = i
        guard plowMass > 0.6, plowClock > 0.08 else { return }
        spray(plowMass, at: CGPoint(x: lead, y: floor + 3), scene)
        plowMass = 0
        plowClock = 0
    }

    /// Takes the snow lying at global x on the Dock or the floor in front of the train; returns how much.
    private func clear(at gx: CGFloat, _ scene: WeatherScene) -> CGFloat {
        var got: CGFloat = 0
        for key in [Surface.dockKey, Surface.groundKey(scene.screenIndex)] {
            guard let s = scene.surfaceByKey[key], gx >= s.rect.minX, gx <= s.rect.maxX,
                  !scene.engine.snap.isCovered(CGPoint(x: gx, y: s.top + 1), behind: s) else { continue }
            got += scene.engine.takeSnow(on: key, at: gx, keep: 0.3)
        }
        return got
    }

    /// Plowed snow flies off ahead in clumps that land a little way on: what it pushes piles up in front.
    private func spray(_ mass: CGFloat, at p: CGPoint, _ scene: WeatherScene) {
        let n = min(3, max(1, Int(mass / 2)))
        let ahead: CGFloat = v > 0 ? dir : -dir
        for _ in 0..<n {
            let s = CGFloat.random(in: 3...5)
            let clump = scene.sprite(Art.flake, size: CGSize(width: s * 1.2, height: s), layer: scene.deskLayer)
            clump.zPosition = Depth.effect
            scene.add(Particle(node: clump, p: p,
                               v: CGVector(dx: ahead * (abs(v) * .random(in: 0.7...1.6) + .random(in: 20...70)),
                                           dy: .random(in: 60...180)),
                               phase: .falling, effect: .snow, terminal: 38 + s * 13, noLand: 0.2, lump: mass / CGFloat(n)))
        }
    }

    private func animate(_ dt: CGFloat, _ scene: WeatherScene) {
        node.position = CGPoint(x: rear, y: floor)
        for w in wheels { w.zRotation -= v * dt / (w.size.width / 2) }
        loco.position.y = Self.lift + abs(sin(t * 14)) * min(1, abs(v) / 150) * 1.5   // chuffs while it rolls
        smoke += dt
        let every: CGFloat = abs(v) > 1 ? 0.12 : 0.35
        let drift: CGFloat = v > 1 ? -dir * 30 : v < -1 ? dir * 30 : 0     // the smoke trails behind
        while smoke > every {
            smoke -= every
            guard phase != .vanishing else { continue }
            let c = CGPoint(x: rear + dir * Self.chimney.x, y: floor + Self.chimney.y)
            scene.emit(Art.glow, at: c, v: CGVector(dx: drift + .random(in: -12...12), dy: .random(in: 40...65)),
                       life: 1.6, size: CGSize(width: 16, height: 16), color: NSColor(calibratedWhite: 0.88, alpha: 1),
                       grow: 2.2, layer: scene.deskLayer)
        }
    }

    /// Hemmed in on both sides: it lets off a cloud of steam and is gone.
    private func vanish(_ scene: WeatherScene) {
        phase = .vanishing
        waited = 0
        for _ in 0..<16 {
            let p = CGPoint(x: rear + dir * .random(in: 0...Self.length), y: floor + .random(in: 10...40))
            scene.emit(Art.glow, at: p, v: CGVector(dx: .random(in: -30...30), dy: .random(in: 20...60)), life: 1.2,
                       size: CGSize(width: 22, height: 22), color: NSColor(calibratedWhite: 0.92, alpha: 1), grow: 2.5,
                       layer: scene.deskLayer)
        }
        node.run(.fadeOut(withDuration: 0.45))
    }

    func clicked(in scene: WeatherScene) {
        scene.say("Toot toot!", at: CGPoint(x: Self.chimney.x, y: 100), in: node)
    }
}
