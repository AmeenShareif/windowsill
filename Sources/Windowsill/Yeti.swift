import SpriteKit
import AppKit

/// The Yeti comes for a snowman. He walks along the floor behind your windows; if the snowman stands
/// on a window he walks to its edge, leaps up, walks along the top, takes it and leaps back down.
/// Click him and he drops it and runs. Everything he stands on, he rides.
final class YetiVisit: Visitor {
    private enum Mode { case approach, leave }
    let node = SKNode()
    private let body = SKSpriteNode(texture: Art.yeti[0], size: Art.yetiSize)
    private var pos: CGPoint                         // local, at his feet
    private var dir: CGFloat = -1                    // the paintings face left
    private var exitDir: CGFloat = 1
    private var target: UUID?
    private var mode = Mode.approach
    private var leap: (from: CGPoint, to: CGPoint, onto: (id: Int, offset: CGFloat)?, k: CGFloat, dur: CGFloat)?
    private var window: (id: Int, offset: CGFloat)?  // the window whose top he stands on
    private var vy: CGFloat = 0
    private var stride: CGFloat = 0
    private var t: CGFloat = 0
    private var carried: SKSpriteNode?
    /// Held up in his raised fists, else hugged in front of him with his arms down.
    private var overhead = true
    /// The smallest he holds a snowman at, so it still reads as the one he took, and where he hugs it.
    private static let held: CGFloat = 0.62
    private static let hug = CGPoint(x: -18, y: 4)
    private var speed: CGFloat = 110
    private var scared = false
    private let width: CGFloat
    private let floor: CGFloat
    var isCarrying: Bool { carried != nil }

    init(scene: WeatherScene) {
        width = scene.size.width
        floor = scene.floorY
        pos = CGPoint(x: width + 50, y: floor)
        let rect = scene.screenRect
        target = scene.engine.decor.snowmen
            .filter { rect.contains(CGPoint(x: $0.x, y: $0.y + 1)) }
            // One up on a window first (the leap is the fun), else the nearest to where he comes in.
            .max { ($0.windowId == nil ? 0 : 1, $0.x) < ($1.windowId == nil ? 0 : 1, $1.x) }?.id
        body.anchorPoint = CGPoint(x: 0.5, y: 0)
        node.addChild(body)
        node.position = pos
        node.zPosition = Depth.visitor
        scene.deskLayer.addChild(node)
    }

    func update(_ dt: CGFloat, in scene: WeatherScene) -> Bool {
        t += dt
        var walking = false
        if leap != nil {
            stepLeap(dt, scene)
        } else if stand(dt, scene) {
            walking = act(dt, scene)
        }
        pose(walking, scene)
        return pos.x > -120 && pos.x < width + 140
    }

    /// Keeps him on what he stands on. False while he is falling (his window went away under him).
    private func stand(_ dt: CGFloat, _ scene: WeatherScene) -> Bool {
        if let w = window {
            if let win = scene.engine.snap.window(w.id) {
                pos = scene.local(CGPoint(x: win.frame.minX + w.offset, y: win.frame.maxY))
                return true
            }
            window = nil
        }
        guard pos.y > floor + 0.5 else { return true }
        vy -= 1500 * dt
        pos.y = max(floor, pos.y + vy * dt)
        if pos.y <= floor {
            vy = 0
            onFloor(scene)
        }
        return false
    }

    private func onFloor(_ scene: WeatherScene) {
        if node.parent !== scene.deskLayer { node.move(toParent: scene.deskLayer) }
        squash(body)
    }

    private func act(_ dt: CGFloat, _ scene: WeatherScene) -> Bool {
        switch mode {
        case .leave:
            if window != nil { return getDown(toward: exitDir, dt, scene) }
            dir = exitDir
            return walk(by: exitDir * speed * dt, scene)
        case .approach:
            guard let id = target, id != scene.engine.draggingId,
                  let man = scene.engine.decor.snowmen.first(where: { $0.id == id }) else {
                leave(scene)
                return false
            }
            let goal = scene.local(CGPoint(x: man.x, y: man.y))
            let side: CGFloat = pos.x >= goal.x ? 1 : -1
            let standX = goal.x + side * 32
            if let wid = man.windowId, let win = scene.engine.snap.window(wid) {
                if window?.id == wid {
                    if let moved = walk(to: standX, dt, scene) { return moved }
                    grab(scene)
                    return false
                }
                if window != nil { return getDown(toward: -side, dt, scene) }
                // From the floor: walk to the window's nearer edge that is on screen, then leap up onto it.
                let l = scene.local(win.frame.origin).x, r = l + win.frame.width
                var edge = side > 0 ? r : l, out = side
                if edge > width - 30 || edge < 30 { edge = side > 0 ? l : r; out = -side }
                if edge > width - 30 || edge < 30 { edge = min(max(standX, 40), width - 40); out = 0 }
                if let moved = walk(to: edge + out * 30, dt, scene) { return moved }
                let landX = edge - out * 22
                leapTo(scene.global(CGPoint(x: landX, y: 0)).x - win.frame.minX, onto: wid, scene)
                return false
            }
            if window != nil { return getDown(toward: -side, dt, scene) }
            guard abs(goal.y - pos.y) < 6 else { return false }      // still falling: wait for it
            if let moved = walk(to: standX, dt, scene) { return moved }
            grab(scene)
            return false
        }
    }

    /// Walks toward local `x`. Returns nil once there, else whether he moved.
    private func walk(to x: CGFloat, _ dt: CGFloat, _ scene: WeatherScene) -> Bool? {
        let dx = x - pos.x
        guard abs(dx) > 2 else { return nil }
        dir = dx < 0 ? -1 : 1
        return walk(by: dir * min(abs(dx), speed * dt), scene)
    }

    private func walk(by dx: CGFloat, _ scene: WeatherScene) -> Bool {
        pos.x += dx
        stride += abs(dx) / 22
        if var w = window, let win = scene.engine.snap.window(w.id) {
            w.offset = scene.global(pos).x - win.frame.minX
            window = w
        }
        return true
    }

    /// Walks to his window's edge on `side`, hops off it clear of the window, then drops to the floor beside
    /// it. Leaping straight for the floor, he came down across the window's title bar and over its buttons
    /// (CI, 2026-11-19).
    private func getDown(toward side: CGFloat, _ dt: CGFloat, _ scene: WeatherScene) -> Bool {
        guard let w = window, let win = scene.engine.snap.window(w.id) else { return false }
        let l = scene.local(win.frame.origin).x, r = l + win.frame.width
        let edge = side < 0 ? l + 14 : r - 14
        if let moved = walk(to: edge, dt, scene) { return moved }
        let out = (side < 0 ? l : r) + side * (Art.yetiSize.width / 2 + 8)
        leap = (from: pos, to: CGPoint(x: out, y: pos.y), onto: nil, k: 0, dur: 0.3)
        window = nil
        dir = side
        return false
    }

    private func leapTo(_ offset: CGFloat, onto wid: Int, _ scene: WeatherScene) {
        guard let win = scene.engine.snap.window(wid) else { return }
        let to = scene.local(CGPoint(x: win.frame.minX + offset, y: win.frame.maxY))
        leap = (from: pos, to: to, onto: (wid, offset), k: 0, dur: 0.45 + (to.y - pos.y) / 1400)
        dir = to.x < pos.x ? -1 : 1
        if node.parent !== scene.visitorLayer { node.move(toParent: scene.visitorLayer) }
    }

    /// Up: fast off the ground, slowing to the top. Down: slow off the edge, fast at the bottom.
    /// A window that moves mid-leap moves where he lands.
    private func stepLeap(_ dt: CGFloat, _ scene: WeatherScene) {
        guard var l = leap else { return }
        if node.parent !== scene.visitorLayer { node.move(toParent: scene.visitorLayer) }
        if let o = l.onto {
            if let win = scene.engine.snap.window(o.id) {
                l.to = scene.local(CGPoint(x: win.frame.minX + o.offset, y: win.frame.maxY))
            } else {
                l.onto = nil
                l.to.y = floor
            }
        }
        l.k = min(1, l.k + dt / l.dur)
        let k = l.k
        let ease = l.to.y > l.from.y ? 1 - (1 - k) * (1 - k) : k * k
        pos = CGPoint(x: l.from.x + (l.to.x - l.from.x) * k, y: l.from.y + (l.to.y - l.from.y) * ease + sin(k * .pi) * 30)
        leap = l
        guard k >= 1 else { return }
        leap = nil
        pos = l.to
        if let o = l.onto {
            window = o
            squash(body)
        } else if pos.y > floor + 0.5 {
            vy = -CGFloat.pi * 30 / l.dur      // off the end of a hop he falls on, as fast as the hop left him
        } else {
            onFloor(scene)
        }
    }

    private func grab(_ scene: WeatherScene) {
        guard let id = target, scene.engine.take(id) != nil else { leave(scene); return }
        let man = SKSpriteNode(texture: Art.snowman, size: Art.snowmanSize)
        man.anchorPoint = CGPoint(x: 0.5, y: 0)
        // Held up in both raised fists when there is room for it under the menu bar, else hugged in front of
        // him. Held up smaller, it shrank to a toy (CI, 2026-11-19); lowered behind his body, he seemed to
        // steal nothing.
        let lift = Art.yetiCarrySizes[0].height - 14
        let room = (scene.ceilingY - pos.y - lift - 2) / Art.snowmanSize.height
        overhead = room >= Self.held
        let scale = overhead ? min(0.7, room) : Self.held
        man.setScale(scale)
        man.zRotation = 0.08
        man.position = overhead ? CGPoint(x: 0, y: lift) : Self.hug
        man.zPosition = overhead ? -1 : 1   // behind the fists, or in front of him (sibling order is ignored)
        node.addChild(man)
        carried = man
        // Over the snowman when there is room, else beside his head, not on top of what he holds: behind him,
        // on the side he came along, since in front stood its neighbour, and it was said on its hat (CI, 2026-11-18).
        let top = overhead ? lift + Art.snowmanSize.height * scale : Art.yetiSize.height
        let words = scene.ceilingY - pos.y - top >= 30 ? CGPoint(x: 0, y: top + 14)
            : CGPoint(x: Art.yetiCarrySizes[0].width / 2 + 36, y: overhead ? lift : Art.yetiSize.height - 20)
        scene.say("Mine!", at: words, in: node)
        leave(scene)
        speed = 150
    }

    /// Off toward the nearer side of the screen.
    private func leave(_ scene: WeatherScene) {
        mode = .leave
        target = nil
        exitDir = pos.x < width / 2 ? -1 : 1
    }

    private func pose(_ walking: Bool, _ scene: WeatherScene) {
        node.position = pos
        node.xScale = dir < 0 ? 1 : -1
        node.childNode(withName: "bubble")?.xScale = node.xScale   // turning round must not mirror his words
        let frame: Int
        let falling = window == nil && pos.y > floor + 0.5
        if leap != nil || falling {
            frame = 1
            body.position.y = 0
            body.zRotation = 0.1
        } else if walking {
            frame = Int(stride) % 2
            body.position.y = abs(sin(stride * .pi)) * 3
            body.zRotation = scared ? 0.13 : 0.05
        } else {
            frame = 0
            body.position.y = 0
            body.zRotation = 0
        }
        let fists = carried != nil && overhead
        body.texture = fists ? Art.yetiCarry[frame] : Art.yeti[frame]
        body.size = fists ? Art.yetiCarrySizes[frame] : Art.yetiSizes[frame]
        // Where he holds it, unless a window carries him up under the menu bar after the grab: then lower.
        if let man = carried {
            let rest = overhead ? Art.yetiCarrySizes[0].height - 14 : Self.hug.y
            man.position.y = min(rest, scene.ceilingY - pos.y - Art.snowmanSize.height * man.yScale - 2)
        }
        // On a window that another window in front covers at his feet, he goes under the window holes like
        // a snowman there: whatever of him stands above that window still shows.
        if leap == nil, let w = window, let s = scene.surfaceByKey[w.id] {
            let hidden = scene.engine.snap.isCovered(CGPoint(x: scene.global(pos).x, y: s.top + 1), behind: s)
            let layer = hidden ? scene.deskLayer : scene.visitorLayer
            if node.parent !== layer { node.move(toParent: layer) }
        }
    }

    func clicked(in scene: WeatherScene) {
        guard !scared else { return }
        scared = true
        leave(scene)
        speed = 400
        scene.say("Eek!", at: CGPoint(x: 0, y: Art.yetiSize.height + 18), in: node)
        if let man = carried {
            man.removeFromParent()
            carried = nil
            // From where he held it: from up at +60, one hugged at his feet popped up before it fell.
            scene.engine.addSnowman(at: scene.global(CGPoint(x: pos.x + man.position.x * node.xScale,
                                                             y: pos.y + man.position.y)))
        }
    }
}
