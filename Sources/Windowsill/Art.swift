import AppKit
import ImageIO
import SpriteKit

/// Particles (flakes, glows, streaks) are drawn here in Core Graphics. Characters and decorations are
/// paintings made in ChatGPT and cut from their sheets by `scripts/import-sprites.py` into Resources/Sprites;
/// the code brings them to life (walk cycles, gallops, swaying, turning wheels).
enum Art {
    /// Every painting the app uses. The selfcheck makes sure each one ships in the bundle.
    static let paintedNames = ["snowman", "snowball", "star", "cane", "tree", "sleigh", "deer-0", "deer-1",
                               "yeti-0", "yeti-1", "yeti-carry-0", "yeti-carry-1", "locomotive", "wagon", "wheel", "elf"]
        + (0..<6).map { "bauble-\($0)" } + (0..<6).map { "present-\($0)" }
        + (0..<4).map { "leaf-\($0)" } + (0..<2).map { "petal-\($0)" }

    static func image(_ name: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Sprites"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func painted(_ name: String) -> SKTexture {
        image(name).map { SKTexture(cgImage: $0) } ?? SKTexture()
    }

    /// Size in points of a painting shown `height` points tall, keeping its proportions.
    static func fit(_ t: SKTexture, height: CGFloat) -> CGSize {
        sizes([t], height: height)[0]
    }

    /// Sizes for pieces cut from one sheet: the first is `height` points tall and the rest keep the
    /// sheet's scale, so the frames of a walk or a gallop stay the same size as each other.
    static func sizes(_ pieces: [SKTexture], height: CGFloat) -> [CGSize] {
        let k = height / max(1, pieces[0].size().height)
        return pieces.map { CGSize(width: ($0.size().width * k).rounded(), height: ($0.size().height * k).rounded()) }
    }

    // MARK: Christmas

    static let snowman = painted("snowman")
    static let snowmanSize = fit(snowman, height: 96)
    static let snowball = painted("snowball")
    static let star = painted("star")
    static let cane = painted("cane")
    static let tree = painted("tree")

    private static let baubles = (0..<6).map { painted("bauble-\($0)") }
    static func bauble(_ i: Int) -> SKTexture { baubles[abs(i) % baubles.count] }
    static let baubleSize = fit(baubles[0], height: 18)

    private static let presents = (0..<6).map { painted("present-\($0)") }
    static func present(_ i: Int) -> SKTexture { presents[abs(i) % presents.count] }
    static let presentSize = fit(presents[0], height: 30)

    /// Santa in his sleigh, and the two frames of a reindeer's gallop. All face left: Santa flies right to left.
    static let sleigh = painted("sleigh")
    static let sleighSize = fit(sleigh, height: 70)
    static let deer = [painted("deer-0"), painted("deer-1")]
    static let deerSizes = sizes(deer, height: 42)

    /// Two walking frames, then the same two with the arms up for carrying a snowman. Facing left.
    static let yeti = [painted("yeti-0"), painted("yeti-1")]
    static let yetiCarry = [painted("yeti-carry-0"), painted("yeti-carry-1")]
    private static let yetiAll = sizes(yeti + yetiCarry, height: 90)
    static let yetiSizes = Array(yetiAll[0..<2])
    static let yetiCarrySizes = Array(yetiAll[2..<4])
    static let yetiSize = yetiAll[0]

    /// The train faces right. Its wheels are separate so they can turn.
    static let locomotive = painted("locomotive")
    static let wagon = painted("wagon")
    private static let trainAll = sizes([locomotive, wagon], height: 64)
    static let locoSize = trainAll[0]
    static let wagonSize = trainAll[1]
    static let wheel = painted("wheel")
    static let elf = painted("elf")

    // MARK: Particles

    static let leaves = (0..<4).map { painted("leaf-\($0)") }
    static let petals = (0..<2).map { painted("petal-\($0)") }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static func bitmap(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func texture(_ size: CGSize, _ draw: (CGContext) -> Void) -> SKTexture {
        let scale: CGFloat = 2
        guard let ctx = bitmap(Int(size.width * scale), Int(size.height * scale)) else { return SKTexture() }
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)
        guard let img = ctx.makeImage() else { return SKTexture() }
        return SKTexture(cgImage: img)
    }

    static func radial(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ colors: [CGColor], _ stops: [CGFloat]) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                 locations: stops) else { return }
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    }

    static func linear(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, _ colors: [CGColor]) {
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                 locations: nil) else { return }
        ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    static let flake = texture(CGSize(width: 16, height: 16)) { ctx in
        // A small snowball lit from the top left: a white highlight over a pale blue-grey body, so a flake
        // falling past a white window shows as a ball. A white centre with a blue rim read there as a hollow ring.
        // The body stays opaque to near the edge: a darker, half-clear rim made it look like a soap bubble.
        let colors = [rgb(1, 1, 1), rgb(0.9, 0.93, 0.98), rgb(0.8, 0.85, 0.94, 0.85), rgb(0.8, 0.85, 0.94, 0)]
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                 locations: [0, 0.45, 0.8, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: CGPoint(x: 5.5, y: 10.5), startRadius: 0,
                               endCenter: CGPoint(x: 8, y: 8), endRadius: 8, options: [])
    }

    static let glow = texture(CGSize(width: 32, height: 32)) { ctx in
        radial(ctx, CGPoint(x: 16, y: 16), 16,
               [rgb(1, 1, 1), rgb(1, 1, 1, 0.55), rgb(1, 1, 1, 0.15), rgb(1, 1, 1, 0)], [0, 0.25, 0.6, 1])
    }

    /// Fully transparent: drawn with the replace blend mode it erases what is under it (see the hole layer).
    static let clear = texture(CGSize(width: 2, height: 2)) { _ in }

    /// The demo's stand-in for the system pointer (screen recordings leave the real one out): the
    /// classic arrow, black with a white rim, its tip at the top left.
    static let cursorSize = CGSize(width: 24, height: 32)
    // Written as fractions of CGFloat: plain `3 / 24` picks CGPoint's Int initialiser and makes the tip (0, 0),
    // which drew the arrow 28 pt above the click in every recording.
    static let cursorTip = CGPoint(x: 3.0 / 24, y: 30.0 / 32)
    static let cursor = texture(cursorSize) { ctx in
        let p = CGMutablePath()
        p.addLines(between: [CGPoint(x: 3, y: 30), CGPoint(x: 3, y: 7), CGPoint(x: 8.5, y: 12), CGPoint(x: 12.5, y: 3),
                             CGPoint(x: 16, y: 4.5), CGPoint(x: 12, y: 13.5), CGPoint(x: 19.5, y: 13.5)])
        p.closeSubpath()
        ctx.addPath(p)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(2.4)
        ctx.setStrokeColor(rgb(1, 1, 1))
        ctx.setFillColor(rgb(0, 0, 0))
        ctx.drawPath(using: .fillStroke)
    }

    static let square = texture(CGSize(width: 4, height: 4)) { ctx in
        ctx.setFillColor(rgb(1, 1, 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    }

    /// A horizontal streak, bright at its head on the right; rotated to point along the velocity.
    static let streak = texture(CGSize(width: 64, height: 4)) { ctx in
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0.5, width: 64, height: 3), cornerWidth: 1.5,
                           cornerHeight: 1.5, transform: nil))
        ctx.clip()
        linear(ctx, CGPoint(x: 0, y: 2), CGPoint(x: 64, y: 2), [rgb(1, 1, 1, 0), rgb(1, 1, 1)])
    }

    /// A raindrop's streak: a pale line beside a blue-grey one, as a lit drop has a shaded side, so rain
    /// shows on a white window as well as on a grey sky.
    static let rainStreak = texture(CGSize(width: 64, height: 4)) { ctx in
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 64, height: 4), cornerWidth: 2,
                           cornerHeight: 2, transform: nil))
        ctx.clip()
        linear(ctx, CGPoint(x: 0, y: 2), CGPoint(x: 64, y: 2), [rgb(0.4, 0.5, 0.64, 0), rgb(0.4, 0.5, 0.64)])
        ctx.clip(to: CGRect(x: 0, y: 2, width: 64, height: 2))
        linear(ctx, CGPoint(x: 0, y: 2), CGPoint(x: 64, y: 2), [rgb(0.86, 0.92, 1, 0), rgb(0.86, 0.92, 1)])
    }
}

/// A gentle pendulum: whatever hangs from a branch or stands in the wind never sits perfectly still.
/// The node turns about its anchor point, so set that first (the hook of a bauble, the base of a snowman).
func sway(_ n: SKNode, by angle: CGFloat, period: TimeInterval) {
    let there = SKAction.rotate(toAngle: angle, duration: period / 2, shortestUnitArc: true)
    let back = SKAction.rotate(toAngle: -angle, duration: period / 2, shortestUnitArc: true)
    there.timingMode = .easeInEaseOut
    back.timingMode = .easeInEaseOut
    n.zRotation = .random(in: -angle...angle)
    n.run(.repeatForever(.sequence([there, back])))
}
