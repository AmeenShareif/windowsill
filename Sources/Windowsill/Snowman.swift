import SpriteKit
import AppKit

/// A snowman rolled out of the snow that has settled on a window, the Dock or the floor. The bottom
/// ball starts as a handful and rolls to where the snowman will stand, taking the snow it rolls over
/// and growing with it, so a bare groove opens behind it. The top ball rolls in from the other side the
/// same way, is lifted on and presses the bottom one down; then the face, scarf and hat pop on.
final class SnowmanBuild: Visitor {
    static let startR: CGFloat = 5, bottomR: CGFloat = 26, topR: CGFloat = 19
    /// Half the width of the painting's bottom ball (55 pt measured): the room a snowman stands in.
    static let footprint: CGFloat = 30
    /// A ball leaves this share of what it rolls over: a thin layer at the bottom of its groove.
    static let keep: CGFloat = 0.15
    /// Snow on a ledge runs back into the screen, so a ball gathers more than the outline shows.
    private static let depth: CGFloat = 3
    /// The top ball stops against the bottom one before it is lifted on.
    static let gap = bottomR + topR - 4
    /// Snow each ball must gather, in square points of outline: what grows it from a handful to full size.
    static let need = (bottom: area(bottomR), top: area(topR))
    private static func area(_ r: CGFloat) -> CGFloat { .pi * (r * r - startR * startR) / depth }
    /// Pressed by the top ball, the bottom one settles to the painting's proportions.
    private static let pressed = (x: CGFloat(1.06), y: CGFloat(0.82))

    private final class Ball {
        let base = SKNode()                       // at the ball's foot, so squashing keeps it on the snow
        let sprite = SKSpriteNode(texture: Art.snowball)
        var x: CGFloat                            // along the surface, from its left end
        let to: CGFloat
        let full: CGFloat, need: CGFloat
        var r = SnowmanBuild.startR
        var got: CGFloat = 0
        var bucket: Int?                          // the last bucket of snow it took

        init(from x: CGFloat, to: CGFloat, full: CGFloat, need: CGFloat) {
            self.x = x
            self.to = to
            self.full = full
            self.need = need
            base.addChild(sprite)
            resize()
        }

        func resize() {
            sprite.size = CGSize(width: 2 * r, height: 2 * r)
            sprite.position = CGPoint(x: 0, y: r)
        }
    }

    let node = SKNode()
    let key: Int
    /// The stretch of the surface (local xs) it rolls over and stands on: no other snowman is planned there.
    let claim: ClosedRange<CGFloat>
    private let stand: CGFloat
    private let bottom: Ball, top: Ball
    private let onWindow: Bool
    private var stage = 0          // 0 the bottom ball rolls, 1 the top one rolls, 2 it is lifted on, 3 the face pops on
    private var t: CGFloat = 0
    private var sprayed: CGFloat = 0
    private var placed = false

    init(_ plan: (stand: CGFloat, bottom: CGFloat, top: CGFloat), on s: Surface, in scene: WeatherScene) {
        key = s.key
        stand = plan.stand
        onWindow = s.key >= 0
        bottom = Ball(from: plan.bottom, to: plan.stand, full: Self.bottomR, need: Self.need.bottom)
        top = Ball(from: plan.top, to: plan.stand + (plan.top > plan.stand ? 1 : -1) * Self.gap, full: Self.topR, need: Self.need.top)
        let lo = min(plan.bottom, plan.top, plan.stand - Self.footprint), hi = max(plan.bottom, plan.top, plan.stand + Self.footprint)
        claim = (lo - Self.bottomR)...(hi + Self.bottomR)
        node.addChild(bottom.base)
        node.addChild(top.base)
        top.base.zPosition = 1                     // in front of the bottom ball once it sits on it
        top.base.alpha = 0
        // On a window it is drawn in front, like a snowman standing there; on the Dock or the floor it is
        // on the desk, behind your windows.
        node.zPosition = Depth.snowman
        (onWindow ? scene.decorLayer : scene.deskLayer).addChild(node)
        appear(bottom)
    }

    private func appear(_ b: Ball) {
        b.base.alpha = 1
        b.base.setScale(0.2)
        let grow = SKAction.scale(to: 1, duration: 0.22)
        grow.timingMode = .easeOut
        b.base.run(grow)
    }

    func update(_ dt: CGFloat, in scene: WeatherScene) -> Bool {
        // The window it was rolled on closed or was minimised: the snowballs fall apart.
        guard let s = scene.surfaceByKey[key] else { return crumble(scene) }
        node.zPosition = scene.depth(Depth.snowman, on: onWindow ? key : nil)
        t += dt
        sprayed += dt
        switch stage {
        case 0:
            if t > 0.25, roll(bottom, dt, s, scene) {
                stage = 1
                t = 0
                appear(top)
            }
            place(top, s, scene)
        case 1:
            if t > 0.25, roll(top, dt, s, scene) {
                stage = 2
                t = 0
            }
        case 2:
            // Lifted in a short arc and set down on the bottom ball.
            let k = min(1, t / 0.45)
            let from = foot(top.x, s, scene), to = CGPoint(x: foot(stand, s, scene).x, y: onTop(s, scene))
            top.base.position = CGPoint(x: from.x + (to.x - from.x) * k,
                                        y: from.y + (to.y - from.y) * (1 - (1 - k) * (1 - k)) + sin(k * .pi) * 26)
            top.sprite.zRotation += dt * 2 * (top.to > stand ? 1 : -1)
            if k >= 1 {
                stage = 3
                t = 0
                top.x = stand
                let press = SKAction.group([.scaleX(to: Self.pressed.x, duration: 0.12), .scaleY(to: Self.pressed.y, duration: 0.12)])
                press.timingMode = .easeOut
                bottom.base.run(press)
                squash(top.base, by: 0.6)
            }
        default:
            top.base.position = CGPoint(x: foot(stand, s, scene).x, y: onTop(s, scene))
            if t > 0.3, !placed {
                placed = true
                scene.engine.placeSnowman(at: s.rect.minX + stand, on: s)
                let head = CGPoint(x: foot(stand, s, scene).x, y: foot(stand, s, scene).y + Art.snowmanSize.height * 0.78)
                scene.poof(at: head, in: onWindow ? nil : scene.deskLayer)
                node.run(.fadeOut(withDuration: 0.2))
            }
            if t > 0.55 { return false }
        }
        place(bottom, s, scene)
        if stage == 1 { place(top, s, scene) }
        hideIfCovered(s, scene)
        return true
    }

    /// Rolls a ball one step toward where it stops, taking the snow under it. True once it is there.
    private func roll(_ b: Ball, _ dt: CGFloat, _ s: Surface, _ scene: WeatherScene) -> Bool {
        let dir: CGFloat = b.to >= b.x ? 1 : -1
        let move = min(abs(b.to - b.x), (70 - b.r) * dt)      // the bigger it gets, the heavier to push
        b.x += dir * move
        let i = Int(b.x / Pile.bucket)
        var j = b.bucket ?? (i - Int(dir))
        while j != i {
            j += Int(dir)
            let h = scene.engine.takeSnow(on: key, at: s.rect.minX + (CGFloat(j) + 0.5) * Pile.bucket, keep: Self.keep)
            b.got += h * Pile.bucket
            if h > 0.3 && sprayed > 0.05 {
                sprayed = 0
                spray(at: foot(b.x, s, scene), dir: dir, scene)
            }
        }
        b.bucket = i
        let share = min(1, b.got / b.need)
        b.r = (Self.startR * Self.startR + (b.full * b.full - Self.startR * Self.startR) * share).squareRoot()
        b.sprite.zRotation -= dir * move / b.r
        b.resize()
        return abs(b.to - b.x) < 0.5
    }

    /// Where a ball's foot is, in the scene: on the surface, down in the groove it has dug.
    private func foot(_ x: CGFloat, _ s: Surface, _ scene: WeatherScene) -> CGPoint {
        let gx = s.rect.minX + x
        let y = s.top - Pile.cornerDrop(at: x, width: s.rect.width, radius: s.corner) + scene.engine.snowDepth(on: key, at: gx)
        return scene.local(CGPoint(x: gx, y: y))
    }

    /// The top ball's foot when it sits on the bottom one, a little sunk into it.
    private func onTop(_ s: Surface, _ scene: WeatherScene) -> CGFloat {
        foot(stand, s, scene).y + 2 * Self.bottomR * bottom.base.yScale - 10
    }

    private func place(_ b: Ball, _ s: Surface, _ scene: WeatherScene) {
        b.base.position = foot(b.x, s, scene)
    }

    /// A little of the snow being gathered is pushed up ahead of the ball.
    private func spray(at p: CGPoint, dir: CGFloat, _ scene: WeatherScene) {
        for _ in 0..<2 {
            scene.emit(Art.flake, at: CGPoint(x: p.x + dir * 4, y: p.y + 2),
                       v: CGVector(dx: dir * .random(in: 15...55), dy: .random(in: 40...110)), life: .random(in: 0.35...0.6),
                       size: CGSize(width: 3.5, height: 3.5), color: .white, gravity: 320,
                       layer: onWindow ? nil : scene.deskLayer)
        }
    }

    /// A ball on a window that another window in front covers is out of sight, like a snowman there.
    private func hideIfCovered(_ s: Surface, _ scene: WeatherScene) {
        guard onWindow else { return }
        for b in [bottom, top] {
            b.base.isHidden = scene.engine.snap.isCovered(CGPoint(x: s.rect.minX + b.x, y: s.top + 1), behind: s)
        }
    }

    private func crumble(_ scene: WeatherScene) -> Bool {
        for b in [bottom, top] where b.base.alpha > 0 && !b.base.isHidden {
            scene.poof(at: CGPoint(x: b.base.position.x, y: b.base.position.y + b.r), in: onWindow ? nil : scene.deskLayer)
        }
        return false
    }

    func clicked(in scene: WeatherScene) {}
}
