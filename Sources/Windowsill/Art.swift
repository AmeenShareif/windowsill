import AppKit
import SpriteKit

/// Every sprite is drawn here with Core Graphics at 2x, so the app ships no image assets.
enum Art {
    /// Apple's 🦌 faces left; Santa flies right to left, so the reindeer lead without flipping.
    static let deerFacesLeft = true

    static let snowmanSize = CGSize(width: 64, height: 100)
    static let sleighSize = CGSize(width: 90, height: 48)
    static let yetiSize = CGSize(width: 70, height: 90)
    static let locoSize = CGSize(width: 110, height: 72)

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

    static func ball(_ ctx: CGContext, _ c: CGPoint, _ r: CGFloat, _ color: CGColor, shade: CGColor) {
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        ctx.clip()
        ctx.setFillColor(shade)
        ctx.fill(CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        radial(ctx, CGPoint(x: c.x - r * 0.35, y: c.y + r * 0.35), r * 1.5, [color, color, shade], [0, 0.45, 1])
        ctx.restoreGState()
    }

    // MARK: Particles

    static let flake = texture(CGSize(width: 16, height: 16)) { ctx in
        radial(ctx, CGPoint(x: 8, y: 8), 8, [rgb(1, 1, 1), rgb(1, 1, 1, 0.9), rgb(1, 1, 1, 0)], [0, 0.45, 1])
    }

    static let glow = texture(CGSize(width: 32, height: 32)) { ctx in
        radial(ctx, CGPoint(x: 16, y: 16), 16,
               [rgb(1, 1, 1), rgb(1, 1, 1, 0.55), rgb(1, 1, 1, 0.15), rgb(1, 1, 1, 0)], [0, 0.25, 0.6, 1])
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

    static let leaves: [SKTexture] = [
        rgb(0.93, 0.47, 0.13), rgb(0.78, 0.2, 0.12), rgb(0.95, 0.7, 0.18), rgb(0.6, 0.32, 0.12),
    ].map { color in
        texture(CGSize(width: 32, height: 32)) { ctx in
            ctx.translateBy(x: 16, y: 16)
            ctx.rotate(by: -0.6)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -12, y: 0))
            p.addQuadCurve(to: CGPoint(x: 13, y: 0), control: CGPoint(x: 0, y: 11))
            p.addQuadCurve(to: CGPoint(x: -12, y: 0), control: CGPoint(x: 0, y: -11))
            ctx.addPath(p)
            ctx.setFillColor(color)
            ctx.fillPath()
            ctx.setStrokeColor(rgb(0.35, 0.15, 0.05, 0.6))
            ctx.setLineWidth(0.8)
            ctx.move(to: CGPoint(x: -15, y: -1))
            ctx.addLine(to: CGPoint(x: 11, y: 0))
            for k in stride(from: -6, through: 6, by: 4) {
                ctx.move(to: CGPoint(x: CGFloat(k), y: 0))
                ctx.addLine(to: CGPoint(x: CGFloat(k) + 3, y: 4))
                ctx.move(to: CGPoint(x: CGFloat(k), y: 0))
                ctx.addLine(to: CGPoint(x: CGFloat(k) + 3, y: -4))
            }
            ctx.strokePath()
        }
    }

    static let petal = texture(CGSize(width: 20, height: 20)) { ctx in
        ctx.addEllipse(in: CGRect(x: 3, y: 2, width: 14, height: 15))
        ctx.clip()
        linear(ctx, CGPoint(x: 10, y: 2), CGPoint(x: 10, y: 17), [rgb(0.98, 0.72, 0.8), rgb(1, 0.9, 0.93)])
        ctx.setBlendMode(.clear)
        ctx.move(to: CGPoint(x: 7.5, y: 18))
        ctx.addLine(to: CGPoint(x: 10, y: 13.5))
        ctx.addLine(to: CGPoint(x: 12.5, y: 18))
        ctx.fillPath()
    }

    // MARK: Christmas

    private static let baubles: [SKTexture] = Ornament.palette.map { ns in
        let color = ns.usingColorSpace(.sRGB)?.cgColor ?? rgb(1, 0, 0)
        return texture(CGSize(width: 14, height: 16)) { ctx in
            ctx.setFillColor(rgb(0.85, 0.7, 0.3))
            ctx.fill(CGRect(x: 5.5, y: 12.5, width: 3, height: 3))
            ball(ctx, CGPoint(x: 7, y: 7), 6.5, color, shade: color.copy(alpha: 1).map { darker($0) } ?? color)
            radial(ctx, CGPoint(x: 5, y: 9.5), 2.4, [rgb(1, 1, 1, 0.9), rgb(1, 1, 1, 0)], [0, 1])
        }
    }

    static func bauble(_ i: Int) -> SKTexture { baubles[abs(i) % baubles.count] }

    static func darker(_ c: CGColor) -> CGColor {
        let p = c.components ?? [0, 0, 0, 1]
        guard p.count >= 3 else { return c }
        return rgb(p[0] * 0.55, p[1] * 0.55, p[2] * 0.55)
    }

    static let star = texture(CGSize(width: 32, height: 32)) { ctx in
        let p = CGMutablePath()
        for k in 0..<10 {
            let r: CGFloat = k % 2 == 0 ? 15 : 6.5
            let a = CGFloat(k) * .pi / 5 + .pi / 2
            let pt = CGPoint(x: 16 + cos(a) * r, y: 16 + sin(a) * r)
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        ctx.addPath(p)
        ctx.saveGState()
        ctx.clip()
        linear(ctx, CGPoint(x: 16, y: 31), CGPoint(x: 16, y: 1), [rgb(1, 0.95, 0.6), rgb(0.98, 0.7, 0.12)])
        ctx.restoreGState()
        ctx.addPath(p)
        ctx.setStrokeColor(rgb(0.8, 0.5, 0.05))
        ctx.setLineWidth(0.8)
        ctx.strokePath()
    }

    /// Origin of the drawing is the trunk's base centre, matching `TreeShape`.
    static let tree = texture(TreeShape.size) { ctx in
        ctx.translateBy(x: TreeShape.size.width / 2, y: 0)
        ctx.setFillColor(rgb(0.4, 0.24, 0.12))
        ctx.fill(CGRect(x: -8, y: 0, width: 16, height: 26))
        for t in TreeShape.tiers {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: -t.half, y: t.base))
            p.addQuadCurve(to: CGPoint(x: t.half, y: t.base), control: CGPoint(x: 0, y: t.base - 8))
            p.addLine(to: CGPoint(x: 0, y: t.apex))
            p.closeSubpath()
            ctx.saveGState()
            ctx.addPath(p)
            ctx.clip()
            linear(ctx, CGPoint(x: -t.half, y: t.base), CGPoint(x: t.half * 0.6, y: t.apex),
                   [rgb(0.05, 0.3, 0.17), rgb(0.12, 0.5, 0.27)])
            ctx.restoreGState()
            // Snow resting on the tips of each tier.
            ctx.setFillColor(rgb(0.97, 0.98, 1))
            var x = -t.half + 6
            while x < t.half - 4 {
                let sag = (t.base - 8) + 8 * pow(x / t.half, 2) * 0.9
                ctx.fillEllipse(in: CGRect(x: x - 5, y: sag - 1, width: 10, height: 6))
                x += 9
            }
        }
    }

    static let snowman = texture(snowmanSize) { ctx in
        let white = rgb(1, 1, 1), shade = rgb(0.78, 0.85, 0.95)
        ctx.setStrokeColor(rgb(0.4, 0.25, 0.12))
        ctx.setLineWidth(2)
        ctx.setLineCap(.round)
        for (a, b, c) in [(CGPoint(x: 19, y: 58), CGPoint(x: 3, y: 72), CGPoint(x: 8, y: 66)),
                          (CGPoint(x: 45, y: 58), CGPoint(x: 61, y: 72), CGPoint(x: 56, y: 66))] {
            ctx.move(to: a); ctx.addLine(to: b)
            ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x + (b.x < 32 ? -4 : 4), y: c.y + 6))
        }
        ctx.strokePath()
        ball(ctx, CGPoint(x: 32, y: 22), 21, white, shade: shade)
        ball(ctx, CGPoint(x: 32, y: 54), 15, white, shade: shade)
        ball(ctx, CGPoint(x: 32, y: 79), 11, white, shade: shade)
        let red = rgb(0.85, 0.12, 0.15)
        ctx.setFillColor(red)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 20, y: 66, width: 24, height: 5), cornerWidth: 2.5, cornerHeight: 2.5,
                           transform: nil))
        ctx.fillPath()
        ctx.fill(CGRect(x: 36, y: 53, width: 6, height: 14))
        ctx.setFillColor(rgb(0.08, 0.08, 0.1))
        ctx.fill(CGRect(x: 19, y: 87, width: 26, height: 3))
        ctx.fill(CGRect(x: 23.5, y: 89, width: 17, height: 11))
        ctx.setFillColor(red)
        ctx.fill(CGRect(x: 23.5, y: 90, width: 17, height: 2.5))
        ctx.setFillColor(rgb(0.08, 0.08, 0.1))
        for c in [CGPoint(x: 28, y: 82), CGPoint(x: 36, y: 82), CGPoint(x: 32, y: 59), CGPoint(x: 32, y: 50),
                  CGPoint(x: 32, y: 41)] {
            ctx.fillEllipse(in: CGRect(x: c.x - 1.5, y: c.y - 1.5, width: 3, height: 3))
        }
        for k in 0..<5 {
            let x = 27 + CGFloat(k) * 2.5, y = 74.5 - (k == 0 || k == 4 ? 0 : 1.2)
            ctx.fillEllipse(in: CGRect(x: x - 0.7, y: y - 0.7, width: 1.4, height: 1.4))
        }
        ctx.setFillColor(rgb(0.98, 0.55, 0.12))
        ctx.move(to: CGPoint(x: 32, y: 79.5))
        ctx.addLine(to: CGPoint(x: 43, y: 77.5))
        ctx.addLine(to: CGPoint(x: 32, y: 76.5))
        ctx.fillPath()
    }

    static let snowball = texture(CGSize(width: 30, height: 30)) { ctx in
        ball(ctx, CGPoint(x: 15, y: 15), 14, rgb(1, 1, 1), shade: rgb(0.78, 0.85, 0.95))
        ctx.setStrokeColor(rgb(0.7, 0.78, 0.9))
        ctx.setLineWidth(1)
        ctx.addArc(center: CGPoint(x: 15, y: 15), radius: 8, startAngle: 0.3, endAngle: 1.9, clockwise: false)
        ctx.strokePath()
    }

    private static let presents: [SKTexture] = [
        (rgb(0.85, 0.12, 0.15), rgb(0.98, 0.8, 0.25)), (rgb(0.1, 0.5, 0.3), rgb(0.95, 0.2, 0.2)),
        (rgb(0.2, 0.4, 0.9), rgb(1, 1, 1)), (rgb(0.6, 0.3, 0.85), rgb(0.98, 0.8, 0.25)),
        (rgb(0.98, 0.78, 0.2), rgb(0.85, 0.12, 0.15)),
    ].map { box, ribbon in
        texture(CGSize(width: 30, height: 30)) { ctx in
            ctx.setFillColor(box)
            ctx.fill(CGRect(x: 3, y: 0, width: 24, height: 19))
            ctx.setFillColor(darker(box))
            ctx.fill(CGRect(x: 1, y: 17, width: 28, height: 6))
            ctx.setFillColor(ribbon)
            ctx.fill(CGRect(x: 13, y: 0, width: 4, height: 23))
            ctx.fillEllipse(in: CGRect(x: 6.5, y: 22, width: 8, height: 6))
            ctx.fillEllipse(in: CGRect(x: 15.5, y: 22, width: 8, height: 6))
        }
    }

    static func present(_ i: Int) -> SKTexture { presents[abs(i) % presents.count] }

    static let sleigh = texture(sleighSize) { ctx in
        let body = CGMutablePath()
        body.move(to: CGPoint(x: 20, y: 12))
        body.addLine(to: CGPoint(x: 80, y: 12))
        body.addQuadCurve(to: CGPoint(x: 84, y: 38), control: CGPoint(x: 88, y: 20))
        body.addLine(to: CGPoint(x: 62, y: 30))
        body.addQuadCurve(to: CGPoint(x: 14, y: 30), control: CGPoint(x: 38, y: 22))
        body.addQuadCurve(to: CGPoint(x: 10, y: 22), control: CGPoint(x: 6, y: 30))
        body.closeSubpath()
        ctx.addPath(body)
        ctx.saveGState()
        ctx.clip()
        linear(ctx, CGPoint(x: 0, y: 38), CGPoint(x: 0, y: 12), [rgb(0.9, 0.15, 0.15), rgb(0.6, 0.05, 0.08)])
        ctx.restoreGState()
        ctx.setStrokeColor(rgb(0.98, 0.8, 0.25))
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: 18, y: 17))
        ctx.addLine(to: CGPoint(x: 80, y: 17))
        ctx.strokePath()
        ctx.setLineWidth(2.5)
        ctx.move(to: CGPoint(x: 86, y: 4))
        ctx.addLine(to: CGPoint(x: 10, y: 4))
        ctx.addQuadCurve(to: CGPoint(x: 6, y: 14), control: CGPoint(x: 0, y: 4))
        for x in [28, 66] {
            ctx.move(to: CGPoint(x: CGFloat(x), y: 4))
            ctx.addLine(to: CGPoint(x: CGFloat(x), y: 12))
        }
        ctx.strokePath()
    }

    static let yeti: [SKTexture] = [0, 1].map { frame in
        texture(yetiSize) { ctx in
            let fur = rgb(0.93, 0.95, 0.99), shade = rgb(0.72, 0.79, 0.9), face = rgb(0.45, 0.53, 0.66)
            ctx.setFillColor(shade)
            let legs = frame == 0 ? [CGRect(x: 18, y: 0, width: 15, height: 20), CGRect(x: 37, y: 0, width: 15, height: 20)]
                                  : [CGRect(x: 13, y: 2, width: 15, height: 18), CGRect(x: 42, y: 0, width: 15, height: 20)]
            legs.forEach { ctx.fillEllipse(in: $0) }
            for arm in [CGRect(x: 1, y: 26, width: 15, height: 34), CGRect(x: 54, y: 26, width: 15, height: 34)] {
                ctx.fillEllipse(in: arm)
            }
            ctx.setFillColor(fur)
            ctx.fillEllipse(in: CGRect(x: 9, y: 10, width: 52, height: 58))
            for k in 0..<18 {   // shaggy outline
                let a = CGFloat(k) / 18 * 2 * .pi
                ctx.fillEllipse(in: CGRect(x: 35 + cos(a) * 25 - 5, y: 39 + sin(a) * 28 - 5, width: 10, height: 10))
            }
            ctx.fillEllipse(in: CGRect(x: 15, y: 50, width: 40, height: 38))
            ctx.setFillColor(rgb(0.55, 0.58, 0.66))
            ctx.fillEllipse(in: CGRect(x: 15, y: 80, width: 8, height: 9))
            ctx.fillEllipse(in: CGRect(x: 47, y: 80, width: 8, height: 9))
            ctx.setFillColor(face)
            ctx.fillEllipse(in: CGRect(x: 21, y: 55, width: 28, height: 24))
            ctx.setFillColor(rgb(1, 1, 1))
            ctx.fillEllipse(in: CGRect(x: 25, y: 66, width: 8, height: 8))
            ctx.fillEllipse(in: CGRect(x: 37, y: 66, width: 8, height: 8))
            ctx.setFillColor(rgb(0.08, 0.08, 0.12))
            ctx.fillEllipse(in: CGRect(x: 27, y: 68, width: 4, height: 4))
            ctx.fillEllipse(in: CGRect(x: 39, y: 68, width: 4, height: 4))
            ctx.fillEllipse(in: CGRect(x: 29, y: 58, width: 12, height: 6))
            ctx.setFillColor(rgb(1, 1, 1))
            ctx.fill(CGRect(x: 31, y: 61, width: 2.5, height: 2.5))
            ctx.fill(CGRect(x: 36.5, y: 61, width: 2.5, height: 2.5))
        }
    }

    static let wagon = texture(CGSize(width: 80, height: 34)) { ctx in
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 4, width: 80, height: 28), cornerWidth: 4, cornerHeight: 4,
                           transform: nil))
        ctx.setFillColor(rgb(0.12, 0.48, 0.3))
        ctx.fillPath()
        ctx.setFillColor(rgb(0.98, 0.8, 0.25))
        ctx.fill(CGRect(x: 0, y: 28, width: 80, height: 4))
        ctx.setFillColor(rgb(0.85, 0.12, 0.15))
        ctx.fill(CGRect(x: 0, y: 12, width: 80, height: 4))
        ctx.setFillColor(rgb(0.2, 0.2, 0.22))
        ctx.fill(CGRect(x: -2, y: 0, width: 84, height: 5))
    }

    static let locomotive = texture(locoSize) { ctx in
        ctx.setFillColor(rgb(0.08, 0.08, 0.1))
        ctx.fill(CGRect(x: -1, y: 56, width: 38, height: 6))
        ctx.fill(CGRect(x: 80, y: 40, width: 12, height: 22))
        ctx.fill(CGRect(x: 77, y: 60, width: 18, height: 6))
        ctx.setFillColor(rgb(0.62, 0.06, 0.1))
        ctx.fill(CGRect(x: 0, y: 6, width: 36, height: 50))
        ctx.setFillColor(rgb(1, 0.9, 0.55))
        ctx.fill(CGRect(x: 8, y: 32, width: 18, height: 16))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 32, y: 6, width: 68, height: 36), cornerWidth: 12, cornerHeight: 12,
                           transform: nil))
        ctx.setFillColor(rgb(0.86, 0.14, 0.16))
        ctx.fillPath()
        ctx.setFillColor(rgb(0.98, 0.8, 0.25))
        for x in [48, 70] { ctx.fill(CGRect(x: CGFloat(x), y: 6, width: 4, height: 36)) }
        ctx.fillEllipse(in: CGRect(x: 56, y: 36, width: 14, height: 12))
        ctx.move(to: CGPoint(x: 98, y: 2))
        ctx.addLine(to: CGPoint(x: 110, y: 2))
        ctx.addLine(to: CGPoint(x: 98, y: 20))
        ctx.fillPath()
        ctx.setFillColor(rgb(1, 0.95, 0.6))
        ctx.fillEllipse(in: CGRect(x: 96, y: 28, width: 9, height: 9))
        ctx.setFillColor(rgb(0.2, 0.2, 0.22))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 7))
    }

    static let wheel = texture(CGSize(width: 32, height: 32)) { ctx in
        ctx.setFillColor(rgb(0.98, 0.8, 0.25))
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: 32, height: 32))
        ctx.setFillColor(rgb(0.17, 0.17, 0.19))
        ctx.fillEllipse(in: CGRect(x: 3, y: 3, width: 26, height: 26))
        ctx.setStrokeColor(rgb(0.98, 0.8, 0.25))
        ctx.setLineWidth(2)
        for k in 0..<6 {
            let a = CGFloat(k) * .pi / 3
            ctx.move(to: CGPoint(x: 16, y: 16))
            ctx.addLine(to: CGPoint(x: 16 + cos(a) * 12, y: 16 + sin(a) * 12))
        }
        ctx.strokePath()
        ctx.setFillColor(rgb(0.98, 0.8, 0.25))
        ctx.fillEllipse(in: CGRect(x: 12.5, y: 12.5, width: 7, height: 7))
    }

    private static var emojiCache: [String: SKTexture] = [:]

    static func emoji(_ s: String, size: CGFloat) -> SKTexture {
        let key = "\(s)@\(size)"
        if let t = emojiCache[key] { return t }
        let box = size * 1.25
        let t = texture(CGSize(width: box, height: box)) { ctx in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size)])
            let b = str.size()
            str.draw(at: CGPoint(x: (box - b.width) / 2, y: (box - b.height) / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        emojiCache[key] = t
        return t
    }
}
