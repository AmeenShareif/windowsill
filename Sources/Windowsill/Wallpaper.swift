import AppKit
import Combine

struct RGB {
    var r, g, b: CGFloat
    init(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { self.r = r; self.g = g; self.b = b }
    func cg(_ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    func mix(_ o: RGB, _ t: CGFloat) -> RGB { RGB(r + (o.r - r) * t, g + (o.g - g) * t, b + (o.b - b) * t) }
    func scaled(_ k: CGFloat) -> RGB { RGB(r * k, g * k, b * k) }
}

/// The sky for one time of day.
struct Sky {
    let top: RGB, bottom: RGB
    let light: CGFloat          // how lit the land is
    let sunY: CGFloat?          // fraction of height; nil = no disc
    let sun: RGB
    let isMoon: Bool
    let stars: CGFloat

    static func at(_ t: TimeOfDay) -> Sky {
        switch t {
        case .dawn: return Sky(top: RGB(0.16, 0.2, 0.38), bottom: RGB(0.88, 0.6, 0.55), light: 0.55, sunY: nil,
                               sun: RGB(1, 0.8, 0.7), isMoon: false, stars: 0.25)
        case .sunrise: return Sky(top: RGB(0.35, 0.5, 0.78), bottom: RGB(1, 0.72, 0.45), light: 0.75, sunY: 0.3,
                                  sun: RGB(1, 0.85, 0.55), isMoon: false, stars: 0)
        case .morning: return Sky(top: RGB(0.35, 0.6, 0.92), bottom: RGB(0.78, 0.88, 0.98), light: 0.95, sunY: 0.62,
                                  sun: RGB(1, 0.98, 0.9), isMoon: false, stars: 0)
        case .midday: return Sky(top: RGB(0.22, 0.5, 0.9), bottom: RGB(0.66, 0.82, 0.97), light: 1, sunY: 0.84,
                                 sun: RGB(1, 1, 0.95), isMoon: false, stars: 0)
        case .golden: return Sky(top: RGB(0.38, 0.55, 0.85), bottom: RGB(1, 0.82, 0.55), light: 0.9, sunY: 0.46,
                                 sun: RGB(1, 0.85, 0.5), isMoon: false, stars: 0)
        case .sunset: return Sky(top: RGB(0.3, 0.25, 0.55), bottom: RGB(1, 0.5, 0.3), light: 0.7, sunY: 0.3,
                                 sun: RGB(1, 0.55, 0.3), isMoon: false, stars: 0.05)
        case .dusk: return Sky(top: RGB(0.1, 0.12, 0.3), bottom: RGB(0.55, 0.35, 0.5), light: 0.45, sunY: 0.72,
                               sun: RGB(0.95, 0.93, 0.85), isMoon: true, stars: 0.5)
        case .night: return Sky(top: RGB(0.02, 0.03, 0.1), bottom: RGB(0.1, 0.13, 0.27), light: 0.28, sunY: 0.76,
                                sun: RGB(0.95, 0.95, 0.88), isMoon: true, stars: 1)
        }
    }
}

enum Wallpaper {
    /// Far-to-near ridge colours in full daylight.
    static func ridges(_ theme: Theme) -> [RGB] {
        switch theme {
        case .winter: return [RGB(0.72, 0.78, 0.9), RGB(0.6, 0.68, 0.83), RGB(0.86, 0.9, 0.97), RGB(0.95, 0.97, 1)]
        case .rain: return [RGB(0.45, 0.5, 0.55), RGB(0.35, 0.42, 0.45), RGB(0.25, 0.33, 0.33), RGB(0.16, 0.22, 0.2)]
        case .stars: return [RGB(0.3, 0.35, 0.5), RGB(0.2, 0.25, 0.4), RGB(0.12, 0.16, 0.28), RGB(0.06, 0.08, 0.15)]
        case .fireflies: return [RGB(0.4, 0.55, 0.5), RGB(0.28, 0.45, 0.35), RGB(0.18, 0.35, 0.22), RGB(0.1, 0.22, 0.12)]
        case .autumn: return [RGB(0.7, 0.55, 0.45), RGB(0.75, 0.45, 0.25), RGB(0.6, 0.3, 0.15), RGB(0.35, 0.18, 0.1)]
        case .spring: return [RGB(0.6, 0.75, 0.65), RGB(0.45, 0.68, 0.45), RGB(0.35, 0.6, 0.3), RGB(0.22, 0.45, 0.2)]
        }
    }

    static func render(_ theme: Theme, _ time: TimeOfDay, width: Int, height: Int) -> CGImage? {
        guard let ctx = Art.bitmap(width, height) else { return nil }
        draw(ctx, theme, time, CGSize(width: width, height: height))
        return ctx.makeImage()
    }

    // ponytail: one painter for every theme with themed foregrounds; hand-painted art per theme would beat it.
    static func draw(_ ctx: CGContext, _ theme: Theme, _ time: TimeOfDay, _ size: CGSize) {
        let w = size.width, h = size.height, u = h / 800
        var sky = Sky.at(time)
        var top = sky.top, bottom = sky.bottom
        if theme == .rain {
            let grey = RGB(0.5, 0.53, 0.58).scaled(0.4 + 0.6 * sky.light)
            top = top.mix(grey, 0.6); bottom = bottom.mix(grey, 0.55)
            sky = Sky(top: top, bottom: bottom, light: sky.light * 0.8, sunY: nil, sun: sky.sun, isMoon: false, stars: 0)
        }
        let themeIndex = UInt64(Theme.allCases.firstIndex(of: theme) ?? 0)
        var rng = SplitMix64(seed: 7919 &* (themeIndex + 1))

        Art.linear(ctx, CGPoint(x: 0, y: h), CGPoint(x: 0, y: h * 0.25), [top.cg(), bottom.cg()])

        let starAmount = theme == .stars ? max(sky.stars * 1.6, sky.light < 0.6 ? 0.4 : 0) : sky.stars
        if starAmount > 0 {
            var srng = SplitMix64(seed: 31 &* (themeIndex + 1))
            for _ in 0..<Int(w * h / 2500 * starAmount) {
                let x = CGFloat.random(in: 0...w, using: &srng), y = CGFloat.random(in: h * 0.3...h, using: &srng)
                let r = CGFloat.random(in: 0.4...1.5, using: &srng) * u
                ctx.setFillColor(RGB(1, 1, 0.95).cg(.random(in: 0.3...0.95, using: &srng) * min(1, starAmount)))
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
            }
        }

        if let sy = sky.sunY {
            let c = CGPoint(x: w * 0.68, y: h * sy)
            Art.radial(ctx, c, h * (sky.isMoon ? 0.22 : 0.4), [sky.sun.cg(0.55), sky.sun.cg(0.18), sky.sun.cg(0)], [0, 0.12, 1])
            let r = h * (sky.isMoon ? 0.03 : 0.04)
            ctx.setFillColor(sky.sun.cg())
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            if sky.isMoon {
                ctx.setFillColor(top.mix(bottom, 0.25).cg(0.85))
                ctx.fillEllipse(in: CGRect(x: c.x - r * 0.45, y: c.y - r * 0.85, width: 2 * r, height: 2 * r))
            }
        }

        let cloudCount = theme == .rain ? 26 : 7
        for _ in 0..<cloudCount {
            let cx = CGFloat.random(in: -0.1...1.1, using: &rng) * w
            let cy = CGFloat.random(in: (theme == .rain ? 0.6 : 0.62)...0.92, using: &rng) * h
            let cw = CGFloat.random(in: 160...420, using: &rng) * u
            let tint = theme == .rain ? RGB(0.42, 0.45, 0.5).scaled(0.5 + 0.5 * sky.light) : RGB(1, 1, 1).mix(bottom, 0.3)
            let alpha = (theme == .rain ? 0.55 : 0.32) * (0.4 + 0.6 * sky.light)
            for k in 0..<4 {
                let ox = CGFloat(k) * cw * 0.22, oy = (k % 2 == 0 ? 0 : cw * 0.06)
                Art.radial(ctx, CGPoint(x: cx + ox, y: cy + oy), cw * 0.32, [tint.cg(alpha), tint.cg(0)], [0, 1])
            }
        }

        let layers = ridges(theme)
        for (i, base) in layers.enumerated() {
            let haze = [0.55, 0.35, 0.18, 0.05][i]
            let color = base.scaled(0.25 + 0.75 * sky.light).mix(bottom, haze)
            let baseline = h * (0.46 - CGFloat(i) * 0.09)
            let amp = h * (0.11 - CGFloat(i) * 0.018)
            let waves = (0..<4).map { _ in
                (f: CGFloat.random(in: 0.6...3.2, using: &rng) / w * 2 * .pi,
                 p: CGFloat.random(in: 0...6.28, using: &rng), a: CGFloat.random(in: 0.2...1, using: &rng))
            }
            let total = waves.reduce(0) { $0 + $1.a }
            func ridgeY(_ x: CGFloat) -> CGFloat {
                baseline + amp * waves.reduce(0) { $0 + $1.a * sin(x * $1.f + $1.p) } / total
            }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: 0))
            var x: CGFloat = 0
            while x <= w + 4 { path.addLine(to: CGPoint(x: x, y: ridgeY(x))); x += 4 }
            path.addLine(to: CGPoint(x: w, y: 0))
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(color.cg())
            ctx.fillPath()
            if i >= 2 { foreground(ctx, theme, layer: i, ridgeY: ridgeY, color: color, sky: sky, w: w, u: u, rng: &rng) }
        }

        weather(ctx, theme, sky: sky, w: w, h: h, u: u, rng: &rng)

        for _ in 0..<Int(w * h / 180) {   // film grain
            let x = CGFloat.random(in: 0...w, using: &rng), y = CGFloat.random(in: 0...h, using: &rng)
            ctx.setFillColor(Bool.random(using: &rng) ? RGB(1, 1, 1).cg(0.035) : RGB(0, 0, 0).cg(0.035))
            ctx.fill(CGRect(x: x, y: y, width: u, height: u))
        }
        Art.radial(ctx, CGPoint(x: w / 2, y: h / 2), hypot(w, h) / 2,
                   [RGB(0, 0, 0).cg(0), RGB(0, 0, 0).cg(0), RGB(0, 0, 0).cg(0.35)], [0, 0.55, 1])
    }

    /// Trees, grass and the like standing on the two nearest ridges.
    private static func foreground(_ ctx: CGContext, _ theme: Theme, layer: Int, ridgeY: (CGFloat) -> CGFloat,
                                   color: RGB, sky: Sky, w: CGFloat, u: CGFloat, rng: inout SplitMix64) {
        let dim = 0.25 + 0.75 * sky.light
        switch theme {
        case .winter, .rain, .stars:
            let pine = (theme == .winter ? RGB(0.12, 0.28, 0.3) : RGB(0.08, 0.16, 0.14)).scaled(dim).mix(color, layer == 2 ? 0.35 : 0)
            for _ in 0..<(layer == 2 ? 26 : 14) {
                let x = CGFloat.random(in: 0...w, using: &rng)
                let ph = CGFloat.random(in: 30...80, using: &rng) * u * (layer == 2 ? 0.7 : 1.2)
                let y = ridgeY(x) - 4 * u
                ctx.setFillColor(pine.cg())
                for k in 0..<3 {
                    let tw = ph * (0.42 - CGFloat(k) * 0.1), ty = y + ph * CGFloat(k) * 0.28
                    ctx.move(to: CGPoint(x: x - tw, y: ty))
                    ctx.addLine(to: CGPoint(x: x + tw, y: ty))
                    ctx.addLine(to: CGPoint(x: x, y: ty + ph * 0.5))
                    ctx.fillPath()
                }
                if theme == .winter {
                    ctx.setFillColor(RGB(0.95, 0.97, 1).scaled(dim).cg(0.9))
                    ctx.move(to: CGPoint(x: x - ph * 0.12, y: y + ph * 0.84))
                    ctx.addLine(to: CGPoint(x: x + ph * 0.12, y: y + ph * 0.84))
                    ctx.addLine(to: CGPoint(x: x, y: y + ph * 1.06))
                    ctx.fillPath()
                }
            }
            if theme == .stars && layer == 3 {   // a still lake reflecting the sky
                let lake = CGRect(x: 0, y: 0, width: w, height: ridgeY(w / 2) * 0.45)
                ctx.saveGState()
                ctx.clip(to: lake)
                Art.linear(ctx, CGPoint(x: 0, y: lake.maxY), CGPoint(x: 0, y: 0),
                           [Sky.at(.night).bottom.mix(color, 0.3).cg(0.9), color.scaled(0.6).cg()])
                ctx.restoreGState()
            }
        case .autumn, .spring:
            let canopy: [RGB] = theme == .autumn
                ? [RGB(0.93, 0.45, 0.12), RGB(0.8, 0.2, 0.1), RGB(0.95, 0.7, 0.2)]
                : [RGB(0.98, 0.72, 0.82), RGB(1, 0.86, 0.9), RGB(0.95, 0.6, 0.75)]
            for _ in 0..<(layer == 2 ? 16 : 9) {
                let x = CGFloat.random(in: 0...w, using: &rng)
                let r = CGFloat.random(in: 18...38, using: &rng) * u * (layer == 2 ? 0.7 : 1.2)
                let y = ridgeY(x)
                ctx.setFillColor(RGB(0.3, 0.18, 0.1).scaled(dim).cg())
                ctx.fill(CGRect(x: x - r * 0.12, y: y - 4 * u, width: r * 0.24, height: r * 1.3))
                for k in 0..<3 {
                    let c = canopy.randomElement(using: &rng)!.scaled(dim).mix(color, layer == 2 ? 0.3 : 0)
                    ctx.setFillColor(c.cg())
                    let ox = CGFloat(k - 1) * r * 0.55, oy = r * (1.3 + (k == 1 ? 0.45 : 0))
                    ctx.fillEllipse(in: CGRect(x: x + ox - r * 0.7, y: y + oy - r * 0.7, width: r * 1.4, height: r * 1.4))
                }
            }
        case .fireflies:
            guard layer == 3 else { return }
            ctx.setStrokeColor(RGB(0.06, 0.16, 0.08).scaled(dim).cg())
            ctx.setLineWidth(1.6 * u)
            var x: CGFloat = 0
            while x < w {
                let bh = CGFloat.random(in: 20...70, using: &rng) * u
                ctx.move(to: CGPoint(x: x, y: 0))
                ctx.addQuadCurve(to: CGPoint(x: x + CGFloat.random(in: -14...14, using: &rng) * u, y: bh),
                                 control: CGPoint(x: x, y: bh * 0.6))
                x += CGFloat.random(in: 2...6, using: &rng) * u
            }
            ctx.strokePath()
        }
    }

    /// Falling things painted into the picture itself.
    private static func weather(_ ctx: CGContext, _ theme: Theme, sky: Sky, w: CGFloat, h: CGFloat, u: CGFloat,
                                rng: inout SplitMix64) {
        switch theme {
        case .winter:
            for _ in 0..<Int(w * h / 9000) {
                let r = CGFloat.random(in: 0.8...2.6, using: &rng) * u
                ctx.setFillColor(RGB(1, 1, 1).cg(.random(in: 0.4...0.9, using: &rng)))
                ctx.fillEllipse(in: CGRect(x: .random(in: 0...w, using: &rng), y: .random(in: 0...h, using: &rng),
                                           width: 2 * r, height: 2 * r))
            }
        case .rain:
            ctx.setStrokeColor(RGB(0.8, 0.85, 0.95).cg(0.25))
            ctx.setLineWidth(1 * u)
            for _ in 0..<Int(w * h / 3000) {
                let x = CGFloat.random(in: 0...w, using: &rng), y = CGFloat.random(in: 0...h, using: &rng)
                let l = CGFloat.random(in: 12...26, using: &rng) * u
                ctx.move(to: CGPoint(x: x, y: y))
                ctx.addLine(to: CGPoint(x: x - l * 0.2, y: y - l))
            }
            ctx.strokePath()
        case .fireflies:
            let glow = max(0.15, 1 - sky.light)
            for _ in 0..<Int(w * h / 22000) {
                let c = CGPoint(x: .random(in: 0...w, using: &rng), y: .random(in: 0...(h * 0.4), using: &rng))
                let r = CGFloat.random(in: 6...14, using: &rng) * u
                Art.radial(ctx, c, r, [RGB(0.9, 1, 0.5).cg(glow), RGB(0.8, 1, 0.4).cg(glow * 0.3), RGB(0.8, 1, 0.4).cg(0)],
                           [0, 0.25, 1])
            }
        case .autumn, .spring:
            let colors = theme == .autumn ? [RGB(0.93, 0.45, 0.12), RGB(0.8, 0.25, 0.1)] : [RGB(1, 0.8, 0.88), RGB(0.98, 0.7, 0.8)]
            for _ in 0..<Int(w * h / 26000) {
                let c = colors.randomElement(using: &rng)!.scaled(0.3 + 0.7 * sky.light)
                ctx.setFillColor(c.cg(0.85))
                let s = CGFloat.random(in: 3...7, using: &rng) * u
                ctx.fillEllipse(in: CGRect(x: .random(in: 0...w, using: &rng), y: .random(in: 0...h, using: &rng),
                                           width: s * 1.6, height: s))
            }
        case .stars:
            guard sky.light < 0.6 else { return }
            for _ in 0..<3 {   // a few shooting stars
                let x = CGFloat.random(in: 0.2...0.9, using: &rng) * w, y = CGFloat.random(in: 0.6...0.95, using: &rng) * h
                let l = CGFloat.random(in: 60...140, using: &rng) * u
                ctx.setStrokeColor(RGB(1, 1, 0.9).cg(0.6))
                ctx.setLineWidth(1.5 * u)
                ctx.move(to: CGPoint(x: x, y: y))
                ctx.addLine(to: CGPoint(x: x - l, y: y - l * 0.45))
                ctx.strokePath()
            }
        }
    }

    static func data(_ img: CGImage, jpeg: Bool) -> Data? {
        let rep = NSBitmapImageRep(cgImage: img)
        return jpeg ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
                    : rep.representation(using: .png, properties: [:])
    }

    /// CI entry point: every theme at every time of day, plus a contact sheet.
    static func renderAll(to dir: URL) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let (w, h, tw, th) = (1280, 800, 240, 150)
            let cols = TimeOfDay.allCases.count
            guard let sheet = Art.bitmap(tw * cols, th * Theme.allCases.count) else { throw CocoaError(.fileWriteUnknown) }
            for (row, theme) in Theme.allCases.enumerated() {
                for (col, time) in TimeOfDay.allCases.enumerated() {
                    guard let img = render(theme, time, width: w, height: h), let png = data(img, jpeg: false) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try png.write(to: dir.appendingPathComponent("\(theme.rawValue)-\(time.rawValue).png"))
                    let y = (Theme.allCases.count - 1 - row) * th
                    sheet.draw(img, in: CGRect(x: col * tw, y: y, width: tw, height: th))
                }
            }
            guard let img = sheet.makeImage(), let png = data(img, jpeg: false) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: dir.appendingPathComponent("sheet.png"))
            print("wrote \(Theme.allCases.count * cols) wallpapers and sheet.png to \(dir.path)")
        } catch {
            print("wallpaper render failed: \(error)")
            exit(1)
        }
    }
}

/// Paints the chosen theme onto every screen and keeps it in step with the clock.
final class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()
    @Published private(set) var thumbs: [Theme: NSImage] = [:]
    private var applied: String?
    private var thumbTime: TimeOfDay?
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "windowsill.wallpaper", qos: .utility)
    private static let keep = 16

    private var state: AppState { AppState.shared }
    var time: TimeOfDay { state.dayNight ? .now() : state.fixedTime }

    private var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Windowsill/wallpapers", isDirectory: true)
    }

    func start() {
        state.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.apply() } }.store(in: &bag)
        let t = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.apply() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        apply()
    }

    func apply() {
        guard let theme = state.theme else { applied = nil; return }
        let time = self.time
        let key = "\(theme.rawValue)-\(time.rawValue)"
        guard key != applied else { return }
        applied = key
        let targets = NSScreen.screens.map { s in
            (screen: s, w: Int(s.frame.width * s.backingScaleFactor), h: Int(s.frame.height * s.backingScaleFactor))
        }
        let folder = self.folder
        queue.async {
            var results: [(NSScreen, URL)] = []
            var failure: String?
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for t in targets {
                    let url = folder.appendingPathComponent("\(key)-\(t.w)x\(t.h).jpg")
                    if !FileManager.default.fileExists(atPath: url.path) {
                        guard let img = Wallpaper.render(theme, time, width: t.w, height: t.h),
                              let data = Wallpaper.data(img, jpeg: true) else { throw CocoaError(.fileWriteUnknown) }
                        try data.write(to: url)
                    }
                    results.append((t.screen, url))
                }
                Self.prune(folder)
            } catch {
                failure = "Couldn't paint the wallpaper: \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                for (screen, url) in results {
                    do {
                        try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                    } catch {
                        failure = "macOS refused the wallpaper: \(error.localizedDescription)"
                    }
                }
                self.state.wallpaperNote = failure
            }
        }
    }

    /// Keeps the newest few renders; each is a few megabytes.
    private static func prune(_ folder: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keep) { try? fm.removeItem(at: url) }
    }

    func loadThumbs() {
        let time = self.time
        guard thumbTime != time else { return }
        thumbTime = time
        queue.async {
            var out: [Theme: NSImage] = [:]
            for theme in Theme.allCases {
                if let img = Wallpaper.render(theme, time, width: 320, height: 200) {
                    out[theme] = NSImage(cgImage: img, size: NSSize(width: 160, height: 100))
                }
            }
            DispatchQueue.main.async { self.thumbs = out }
        }
    }
}
