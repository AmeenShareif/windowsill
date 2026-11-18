import AppKit
import ServiceManagement
import SwiftUI

/// `--demo <effect|christmas|panel> [--shots <dir>]`: a scripted run for CI screenshots and videos.
/// The app asks for a screenshot by dropping `<dir>/<mode>-<name>.req`; scripts/demo-shots.sh takes it,
/// and records the whole run as `<dir>/<mode>.mov`. A drawn pointer stands in for the mouse, which a
/// recording leaves out: it drags windows by their title bars, shakes, resizes and closes them, and
/// clicks and drags the decorations, so every feature is seen doing what it does.
enum Demo {
    static func parse(_ args: [String]) -> String? {
        guard let i = args.firstIndex(of: "--demo"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// How long each run lasts, in seconds; demo-shots.sh records a little longer.
    static func length(_ mode: String) -> TimeInterval {
        switch mode {
        case "christmas": return 64
        case "panel": return 23
        default: return 35
        }
    }
}

final class DemoRun {
    private enum Curve { case smooth, accelerate }
    private let mode: String
    private let shots: URL?
    private let engine = Engine.shared
    private var windows: [NSWindow] = []
    private var timers: [Timer] = []
    /// Frames drawn and the time at the previous shot, for the frame rate between shots.
    private var lastShot: (frames: Int, at: TimeInterval) = (0, 0)
    /// What the panel demo measured on its way to the next shot.
    private var panelNote: String?

    private static let looks: [String: (Theme, TimeOfDay)] = [
        "snow": (.winter, .morning), "leaves": (.autumn, .golden), "starfall": (.stars, .night),
        "rain": (.rain, .midday), "sakura": (.spring, .morning), "fireflies": (.fireflies, .dusk),
        "christmas": (.winter, .night), "panel": (.autumn, .golden),
    ]

    init(_ mode: String) {
        self.mode = mode
        let args = CommandLine.arguments
        shots = args.firstIndex(of: "--shots").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
    }

    private func at(_ t: TimeInterval, _ f: @escaping () -> Void) {
        let timer = Timer(timeInterval: t, repeats: false) { _ in f() }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func shot(_ name: String) {
        guard let dir = shots else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("\(mode)-\(name).req").path, contents: nil)
        try? stateDump().write(to: dir.appendingPathComponent("\(mode)-\(name).txt"), atomically: true, encoding: .utf8)
    }

    /// What the tracker and the scene see at a shot, so a shot that looks wrong can be explained.
    private func stateDump() -> String {
        func rect(_ r: CGRect) -> String { "x \(Int(r.minX))...\(Int(r.maxX)) y \(Int(r.minY))...\(Int(r.maxY))" }
        let cg = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var lines = cg.map { i -> String in
            let b = (i[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            return "cg \(i[kCGWindowNumber as String] ?? "?") layer \(i[kCGWindowLayer as String] ?? "?") "
                + "\(i[kCGWindowOwnerName as String] ?? "?") / \(i[kCGWindowName as String] ?? "") "
                + "alpha \(i[kCGWindowAlpha as String] ?? "?") quartz \(rect(b))"
        }
        lines += engine.snap.surfaces.map { "surface \($0.key) order \($0.order) \(rect($0.rect))" }
        lines += engine.piles.map { k, p in
            "pile \(k) " + p.heights.map { String(min(9, Int(($0 / 1.5).rounded()))) }.joined()
        }
        lines += (engine.mainScene?.landed ?? [:]).map { "landed \($0.key) \($0.value)" }
        lines.append("pointer \(engine.pointer) view paused \(engine.mainScene?.view?.isPaused ?? true)")
        if let p = panelNote { lines.append(p); panelNote = nil }
        if let scene = engine.mainScene {
            let now = ProcessInfo.processInfo.systemUptime
            if lastShot.at > 0 {
                let fps = Double(scene.frameCount - lastShot.frames) / (now - lastShot.at)
                lines.append(String(format: "frames %.1f fps since the last shot, longest gap %.1f ms", fps, scene.longestGap * 1000))
            }
            lastShot = (scene.frameCount, now)
            scene.longestGap = 0
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func start() {
        let state = AppState.shared
        let christmas = mode == "christmas"
        engine.pileBoost = 8
        state.inScreenshots = true   // the recording is a screenshot: the overlay must be in it
        state.enabled = true
        state.effect = christmas ? .snow : (Effect(rawValue: mode) ?? .snow)
        state.showDecor = christmas
        // The desktop picture belongs to the user; only a CI runner gets one painted.
        if ProcessInfo.processInfo.environment["CI"] != nil, let look = Self.looks[mode] {
            state.dayNight = false
            state.fixedTime = look.1
            state.theme = look.0
        }
        guard let f = NSScreen.screens.first?.visibleFrame else { return }
        at(1.0) { print("demo \(self.mode): dock \(self.engine.snap.dock.map { "\($0)" } ?? "not found"), floor \(self.engine.mainScene?.floorY ?? -1)") }
        at(Demo.length(mode)) { NSApp.terminate(nil) }
        if mode == "panel" { return showPanel(f) }
        // At Christmas the windows sit clear of the trees, so they can be decorated; one is slid over a tree later.
        // Their tops stay well under the menu bar: a snowman needs about 100 pt of headroom to stand there.
        let (y0, h0, y1, h1): (CGFloat, CGFloat, CGFloat, CGFloat) = christmas ? (0.4, 0.36, 0.5, 0.26) : (0.16, 0.44, 0.3, 0.38)
        windows = [
            makeWindow("Notes", CGRect(x: f.minX + f.width * 0.08, y: f.minY + f.height * y0,
                                       width: f.width * 0.42, height: f.height * h0)),
            makeWindow("Windowsill demo", CGRect(x: f.minX + f.width * 0.4, y: f.minY + f.height * y1,
                                                 width: f.width * 0.4, height: f.height * h1)),
        ]
        NSApp.activate()
        engine.pointerOverride = CGPoint(x: f.midX, y: f.minY + f.height * 0.1)
        christmas ? christmasTour(f) : weatherTour(f)
    }

    // MARK: - Weather: build up, ride a slow drag, shake, resize, brush, close, rest and flick, fling

    private func weatherTour(_ f: CGRect) {
        guard let back = windows.first, let front = windows.last else { return }
        at(7.5) { self.shot("build") }
        at(8.0) { self.glide(to: { self.titleBar(front) }, over: 0.7) }
        at(8.9) { self.drag(front, by: CGVector(dx: -220, dy: 60), over: 2.4) }      // slow and steady: it all rides
        at(10.4) { self.shot("drag") }
        at(11.6) { self.shake(front) }                                                // jolts throw it off
        at(12.0) { self.shot("shake") }
        at(13.4) { self.resize(back, by: -0.3 * back.frame.width) }                  // drops what hung past the edge
        at(15.4) { self.shot("resize") }
        at(16.0) { self.brush(along: back) }                                          // leaves and petals scatter
        at(17.0) { self.shot("brush") }
        at(18.0) { front.orderOut(nil) }                                              // a closed window drops it all
        at(18.5) { self.shot("close") }
        at(19.5) { self.glide(to: { CGPoint(x: f.midX + 160, y: f.maxY - f.height * 0.2) }, over: 0.8) }
        at(22.6) { self.shot("rest") }                                                // fireflies gather on a still pointer
        at(23.0) { self.glide(to: { CGPoint(x: f.midX - 380, y: f.maxY - f.height * 0.3) }, over: 0.18) }
        at(23.2) { self.shot("flick") }                                               // and scatter from a flick
        at(24.0) { self.glide(to: { self.titleBar(back) }, over: 0.6) }
        at(24.8) { self.drag(back, by: CGVector(dx: 280, dy: 120), over: 0.32, curve: .accelerate) }   // a fling
        at(25.4) { self.shot("fling") }
        at(26.5) { AppState.shared.behindWindows = true }                                // it falls behind the window
        at(29.0) { self.shot("behind") }
        at(29.5) {
            let state = AppState.shared
            state.behindWindows = false
            guard state.effect == .snow else { return }
            state.intensity = 0.25                                                      // a light fall, and the piles thaw
            state.melt = true
            self.engine.meltBoost = 40
        }
        if mode == "snow" { at(33.5) { self.shot("melt") } }
    }

    // MARK: - Christmas: decorate, Santa, carry a present, ride, knock off, open, train, depth, Yeti

    private func christmasTour(_ f: CGRect) {
        guard let back = windows.first, let front = windows.last else { return }
        at(0.6) { self.engine.growTree(); self.engine.growTree() }
        at(2.4) { self.decorateByHand() }                                             // ~3.5 s of clicks
        at(6.4) { self.decorate(skippingFirst: true) }
        at(7.0) {                                                                     // rolled from the settled snow
            self.engine.rollSnowman(on: front.windowNumber)
            self.engine.rollSnowman(on: back.windowNumber)
        }
        at(9.0) { self.shot("rolling") }
        at(12.6) { self.engine.rollSnowman(on: Surface.dockKey) }                   // the train must stop short of it
        at(14.2) { self.shot("decorated") }
        at(10.0) { self.engine.mainScene?.callSanta() }                               // drops a present as he passes
        at(15.5) { self.shot("santa") }
        at(16.0) { self.carryPresent(onto: front) }                                   // ~2.6 s
        at(19.4) { self.glide(to: { self.titleBar(front) }, over: 0.6) }
        // Down, not up: raised into the menu bar the snowman would be knocked off.
        at(20.2) { self.drag(front, by: CGVector(dx: -170, dy: -40), over: 2.2) }    // snowman, present and snow ride
        at(21.3) { self.shot("ride") }
        at(23.0) { self.shake(front) }                                                // the present is knocked off
        at(23.7) { self.shot("knocked") }
        at(25.0) { self.openAPresent() }                                              // confetti; a bauble flies to a tree
        at(26.2) { self.shot("opened") }
        at(27.0) { self.engine.mainScene?.sendTrain() }                               // along the floor, behind the windows
        at(30.1) { self.shot("train") }                                               // stopped short; the gift in the air
        at(30.0) { self.glide(to: { self.titleBar(back) }, over: 0.6) }
        at(30.7) { self.coverTree(with: back) }                                       // a window slides over a tree
        at(32.8) { self.shot("depth") }
        at(35.0) { self.carrySnowman(besideOneOn: [front, back]) }                   // ~2 s; the Yeti wants it
        at(37.8) { self.shot("made-room") }                                          // set down beside the other, it shuffles aside
        at(38.0) { self.engine.mainScene?.summonYeti() }                             // walks, leaps up, steals it
        at(39.0) { self.scareYetiOnceHeHasIt() }
        at(50.0) { self.glide(to: { self.titleBar(back) }, over: 0.6) }
        // Raised into the menu bar, the snowman on it bumps its head and falls off.
        at(50.7) { self.drag(back, by: CGVector(dx: 0, dy: back.screen.map { $0.visibleFrame.maxY - back.frame.maxY - 20 } ?? 80), over: 1.0) }
        at(52.0) { self.shot("ceiling") }
        at(58.0) { self.shot("end") }
    }

    // MARK: - The scripted pointer

    /// Moves the drawn pointer to a (possibly moving) target; `step` sees each position on the way.
    private func glide(to target: @escaping () -> CGPoint, over d: TimeInterval, curve: Curve = .smooth,
                       step: ((CGPoint) -> Void)? = nil, then: (() -> Void)? = nil) {
        let engine = engine
        let a = engine.pointerOverride ?? target()
        let t0 = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { t in
            let k = CGFloat(min(1, (CACurrentMediaTime() - t0) / max(d, 0.001)))
            let e = curve == .smooth ? k * k * (3 - 2 * k) : k * k
            let b = target()
            let q = CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
            engine.pointerOverride = q
            step?(q)
            if k >= 1 {
                t.invalidate()
                then?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func titleBar(_ w: NSWindow) -> CGPoint { CGPoint(x: w.frame.midX - 70, y: w.frame.maxY - 13) }

    private func ring() {
        guard let s = engine.mainScene, let p = engine.pointerOverride else { return }
        s.showClick(at: s.local(p))
    }

    /// Drags a window by its title bar: the pointer presses where it is and the window follows it.
    private func drag(_ w: NSWindow, by d: CGVector, over t: TimeInterval, curve: Curve = .smooth, press: Bool = true,
                      then: (() -> Void)? = nil) {
        let p0 = engine.pointerOverride ?? titleBar(w)
        let o0 = w.frame.origin
        if press { ring() }
        glide(to: { CGPoint(x: p0.x + d.dx, y: p0.y + d.dy) }, over: t, curve: curve,
              step: { q in w.setFrameOrigin(CGPoint(x: o0.x + q.x - p0.x, y: o0.y + q.y - p0.y)) }, then: then)
    }

    private func shake(_ w: NSWindow) {
        drag(w, by: CGVector(dx: 130, dy: 0), over: 0.1) {
            self.drag(w, by: CGVector(dx: -260, dy: 0), over: 0.16, press: false) {
                self.drag(w, by: CGVector(dx: 130, dy: 0), over: 0.1, press: false)
            }
        }
    }

    /// Takes the bottom-right corner and pulls it in by `dw`.
    private func resize(_ w: NSWindow, by dw: CGFloat) {
        let f0 = w.frame
        glide(to: { CGPoint(x: f0.maxX - 3, y: f0.minY + 3) }, over: 0.6, then: {
            self.ring()
            let p0 = self.engine.pointerOverride ?? CGPoint(x: f0.maxX, y: f0.minY)
            self.glide(to: { CGPoint(x: p0.x + dw, y: p0.y) }, over: 1.0, step: { q in
                w.setFrame(CGRect(x: f0.minX, y: f0.minY, width: f0.width + q.x - p0.x, height: f0.height), display: true)
            })
        })
    }

    /// A quick sweep just above a window's top edge.
    private func brush(along w: NSWindow) {
        let y = w.frame.maxY + 8
        glide(to: { CGPoint(x: w.frame.minX - 30, y: y) }, over: 0.5, then: {
            self.glide(to: { CGPoint(x: w.frame.maxX + 30, y: y) }, over: 0.45)
        })
    }

    /// Glides to a (possibly moving) point and clicks there.
    private func click(_ target: @escaping () -> CGPoint, over d: TimeInterval = 0.35) {
        glide(to: target, over: d, then: {
            guard let s = self.engine.mainScene, let p = self.engine.pointerOverride else { return }
            let l = s.local(p)
            s.showClick(at: l)
            s.pointerDown(l)
            s.pointerUp()
        })
    }

    // MARK: - Christmas steps

    /// Picks a tool from the panel and clicks the first tree with it, the way a person decorates.
    private func decorateByHand() {
        guard let tree = engine.decor.trees.first else { return }
        let state = AppState.shared
        let steps: [(Tool, CGFloat, CGFloat)] = [
            (.bauble, -30, 60), (.bauble, 26, 86), (.bauble, -12, 132), (.bauble, 20, 40),
            (.lights, 0, 110), (.cane, 34, 52), (.star, 0, TreeShape.apex.y),
        ]
        for (i, s) in steps.enumerated() {
            at(Double(i) * 0.5) {
                state.tool = s.0
                self.click({ CGPoint(x: tree.x + s.1, y: tree.y + s.2) })
            }
        }
        at(Double(steps.count) * 0.5) { state.tool = .move }
    }

    private func decorate(skippingFirst: Bool) {
        let baubles: [(CGFloat, CGFloat)] = [(-30, 60), (25, 85), (-12, 130), (18, 40), (0, 165), (-36, 30)]
        for tree in engine.decor.trees.dropFirst(skippingFirst ? 1 : 0) {
            engine.addOrnament(Ornament(kind: .star, x: 0, y: TreeShape.apex.y, color: 0), to: tree.id)
            engine.addOrnament(Ornament(kind: .lights, x: 0, y: 112, color: 0), to: tree.id)
            engine.addOrnament(Ornament(kind: .lights, x: 0, y: 62, color: 0), to: tree.id)
            engine.addOrnament(Ornament(kind: .cane, x: 34, y: 50, color: 0), to: tree.id)
            for (i, b) in baubles.enumerated() {
                engine.addOrnament(Ornament(kind: .bauble, x: b.0, y: b.1, color: i % Ornament.palette.count), to: tree.id)
            }
        }
        for tree in engine.decor.trees { engine.addPresent(at: CGPoint(x: tree.x + 58, y: tree.y), anchored: true) }
    }

    /// Picks up a present from under a tree and drops it above a window: it falls and lands there.
    private func carryPresent(onto w: NSWindow) {
        guard let gift = reachablePresent(anchored: true) else { return }
        carry(from: CGPoint(x: gift.x, y: gift.y + 12), to: CGPoint(x: w.frame.midX + 90, y: w.frame.maxY + 70))
    }

    /// Lifts a snowman standing on the floor and sets it down too close to one already on a window: it
    /// shuffles aside to make room. With none left on those windows it goes on the first one's right end.
    /// The train may be passing in front of it: then try again a moment later.
    private func carrySnowman(besideOneOn windows: [NSWindow], tries: Int = 12) {
        guard let s = engine.mainScene,
              let man = engine.decor.snowmen.last(where: { m in
                  guard m.windowId == nil, case .snowman(let id)? = s.hit(s.local(CGPoint(x: m.x, y: m.y + 40))) else { return false }
                  return id == m.id
              }) else {
            if tries > 0 { at(0.25) { self.carrySnowman(besideOneOn: windows, tries: tries - 1) } }
            return
        }
        let ids = windows.map(\.windowNumber)
        let beside = engine.decor.snowmen.compactMap { m -> CGPoint? in
            guard let wid = m.windowId, ids.contains(wid) else { return nil }
            let p = CGPoint(x: m.x + 24, y: m.y + 110)
            // Only where that window is the first thing it meets on the way down, not a higher one behind.
            return engine.snap.support(x: p.x, y: p.y - 40, height: Art.snowmanSize.height)?.key == wid ? p : nil
        }.first
        let to = beside ?? windows.first.map { CGPoint(x: $0.frame.maxX - 70, y: $0.frame.maxY + 110) }
        guard let to else { return }
        carry(from: CGPoint(x: man.x, y: man.y + 40), to: to)
    }

    /// Presses on whatever is at `a`, drags it to `b` and lets go there: it falls onto what is below.
    private func carry(from a: CGPoint, to b: CGPoint) {
        glide(to: { a }, over: 0.7, then: {
            guard let s = self.engine.mainScene else { return }
            s.showClick(at: s.local(a))
            s.pointerDown(s.local(a))
            self.glide(to: { b }, over: 1.2, step: { q in s.pointerDragged(s.local(q)) }, then: { s.pointerUp() })
        })
    }

    /// A present the pointer can actually reach, not one behind a window. `anchored` nil means any.
    private func reachablePresent(anchored: Bool?) -> PresentItem? {
        guard let s = engine.mainScene else { return nil }
        return engine.decor.presents.last { g in
            guard anchored == nil || g.anchored == anchored,
                  case .present(let id)? = s.hit(s.local(CGPoint(x: g.x, y: g.y + 12))) else { return false }
            return id == g.id
        }
    }

    private func openAPresent() {
        guard let gift = reachablePresent(anchored: nil) else { return }
        let id = gift.id
        click({
            let g = self.engine.decor.presents.first { $0.id == id } ?? gift
            return CGPoint(x: g.x, y: g.y + 12)
        }, over: 0.6)
    }

    /// Slides a window across a tree and back: the tree stands behind it.
    private func coverTree(with w: NSWindow) {
        guard let tree = engine.decor.trees.min(by: { abs($0.x - w.frame.midX) < abs($1.x - w.frame.midX) }) else { return }
        let dx = tree.x - w.frame.midX
        let dy = min(0, tree.y + 120 - w.frame.minY)
        drag(w, by: CGVector(dx: dx, dy: dy), over: 1.4)
        at(2.6) {
            self.drag(w, by: CGVector(dx: -dx, dy: -dy), over: 1.2, press: false)
        }
    }

    /// Waits for the Yeti to make off with a snowman, then clicks him once he can be reached.
    private func scareYetiOnceHeHasIt() {
        var tries = 0
        let poll = Timer(timeInterval: 0.2, repeats: true) { [weak self] t in
            tries += 1
            guard let self, let s = self.engine.mainScene, tries < 120 else { t.invalidate(); return }
            guard let yeti = s.visitors.compactMap({ $0 as? YetiVisit }).first, yeti.isCarrying else { return }
            let spot = CGPoint(x: yeti.node.position.x, y: yeti.node.position.y + 40)
            guard case .visitor(_)? = s.hit(spot) else { return }
            t.invalidate()
            self.shot("yeti-steals")
            self.click({ s.global(CGPoint(x: yeti.node.position.x, y: yeti.node.position.y + 40)) }, over: 0.4)
            self.at(0.9) { self.shot("yeti-scared") }
        }
        RunLoop.main.add(poll, forMode: .common)
        timers.append(poll)
    }

    // MARK: - Panel

    /// The menu bar panel on popover material, as the menu bar shows it: every tab, light then dark.
    private func showPanel(_ f: CGRect) {
        func ms(since t: CFTimeInterval) -> String { String(format: "%.1f ms", (CACurrentMediaTime() - t) * 1000) }
        /// The longest gap between two weather frames since the last read.
        func gap() -> String {
            guard let s = engine.mainScene else { return "?" }
            defer { s.longestGap = 0 }
            return String(format: "%.1f ms", s.longestGap * 1000)
        }
        let state = AppState.shared
        state.showDecor = true // the Christmas tab is shown live, not greyed out
        state.dayNight = false
        state.fixedTime = .golden
        let w = NSWindow(contentRect: CGRect(x: f.midX - 172, y: f.maxY - 640, width: 344, height: 600),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.level = AboveTheWeather.level   // where the real panel floats: over the falling weather
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        let material = NSVisualEffectView()
        material.material = .popover
        material.state = .active
        // A mask image, not a rounded layer: the window server shapes the shadow and the dark-mode rim from it.
        let corner: CGFloat = 12
        let mask = NSImage(size: NSSize(width: 2 * corner + 1, height: 2 * corner + 1), flipped: false) { rect in
            NSColor.black.set()
            NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: corner, left: corner, bottom: corner, right: corner)
        mask.resizingMode = .stretch
        material.maskImage = mask
        w.contentView = material

        let steps: [(PanelView.Tab, Effect, Bool)] = [
            (.weather, .snow, false), (.christmas, .snow, false), (.wallpaper, .leaves, false), (.settings, .sakura, false),
            (.weather, .fireflies, true), (.christmas, .starfall, true), (.wallpaper, .rain, true), (.settings, .snow, true),
        ]
        // One panel for the whole demo, its tabs changed through its own segmented control as a click does.
        var host: NSHostingView<PanelView>!
        /// Fits the panel to its content, as the menu bar does, and says how long measuring and resizing took.
        func fit(grow: CGFloat = 0) -> String {
            let t = CACurrentMediaTime()
            var s = host.fittingSize
            s.height += grow
            let measured = ms(since: t)
            let r = CACurrentMediaTime()
            host.frame = CGRect(origin: .zero, size: s)
            w.setContentSize(s)
            w.setFrameTopLeftPoint(CGPoint(x: f.midX - 172, y: f.maxY - 20))
            w.invalidateShadow()
            return "measure \(measured), resize \(ms(since: r))"
        }
        // The panel opens once the weather has run a moment, as a click on the menu bar icon finds it. Opened
        // at launch, its gap also held the weather's own first frames, so launch is read on its own first.
        var openNote = ""
        at(0.6) {
            let launch = "longest gap at launch \(gap())"
            let opened = CACurrentMediaTime()
            w.orderFrontRegardless()
            self.windows = [w]
            NSApp.activate()
            host = NSHostingView(rootView: PanelView(tab: steps[0].0))
            host.autoresizingMask = [.width, .height]
            material.addSubview(host)
            let firstFit = fit()
            let openTime = ms(since: opened)
            WallpaperManager.shared.loadThumbs()
            let login = CACurrentMediaTime()
            _ = SMAppService.mainApp.status
            openNote = "\(launch); opening built and fitted in \(openTime) (\(firstFit)), login item status read \(ms(since: login))"
        }
        var openGap = ""
        at(0.98) { openGap = "longest gap over opening it \(gap())" }

        // After the last tab, the same panel grows and shrinks with nothing new in it: what resizing alone costs.
        var probe: [String] = []
        at(18.7) { _ = gap() }
        at(18.8) { probe.append("grown by 60 pt: \(fit(grow: 60))") }
        at(19.3) { probe.append("longest gap over growing \(gap())") }
        at(19.4) { probe.append("shrunk back: \(fit())") }
        at(19.9) { probe.append("longest gap over shrinking \(gap())") }
        // Last, the overlay stepped out of screenshots: this one should show the desktop and the panel, no weather.
        at(20.4) { state.inScreenshots = false }
        at(21.4) {
            self.panelNote = "panel " + probe.joined(separator: "; ")
            self.shot("hidden")
        }
        for (i, step) in steps.enumerated() {
            let t0 = 1.5 + Double(i) * 2.2
            var note: [String] = []
            // Light or dark, then the weather, then the tab, each on its own, so each hitch has one cause.
            at(t0 - 0.5) {
                if i == 0 { note += [openNote, openGap] }
                let look: NSAppearance.Name = step.2 ? .darkAqua : .aqua
                guard NSApp.appearance?.name != look else { return }
                let t = CACurrentMediaTime()
                NSApp.appearance = NSAppearance(named: look)
                note.append("look set \(ms(since: t))")
            }
            at(t0 - 0.28) {
                if note.last?.hasPrefix("look set") == true { note.append("longest gap after the look \(gap())") }
                guard state.effect != step.1 else { return }
                _ = gap()
                let t = CACurrentMediaTime()
                state.effect = step.1
                note.append("weather set \(ms(since: t))")
            }
            at(t0 - 0.02) {
                let g = gap()   // read either way, so the tab's gap below starts here
                if note.last?.hasPrefix("weather set") == true { note.append("longest gap after the weather \(g)") }
            }
            at(t0) {
                let t = CACurrentMediaTime()
                if let seg = Self.tabControl(in: host), let n = PanelView.Tab.allCases.firstIndex(of: step.0) {
                    seg.selectedSegment = n
                    _ = seg.sendAction(seg.action, to: seg.target)
                    note.append("tab clicked \(ms(since: t))")
                } else {
                    note.append("tab control not found")
                }
            }
            // The new tab is built and drawn on the next pass of the run loop; the panel is fitted to it after.
            at(t0 + 0.13) { note.append("longest gap over building the tab \(gap())") }
            at(t0 + 0.15) { note.append("fit: \(fit())") }
            at(t0 + 0.6) { note.append("longest gap over fitting the panel \(gap())") }
            // Thumbnails arrive after the first layout and grow the panel: fit it again before the shot.
            at(t0 + 0.7) { note.append("refit: \(fit())") }
            at(t0 + 1.6) {
                self.panelNote = "panel " + note.joined(separator: "; ")
                self.shot("\(step.2 ? "dark" : "light")-\(step.0.rawValue.lowercased())")
            }
        }
    }

    /// The panel's own tab picker: the segmented control with one segment per tab.
    private static func tabControl(in v: NSView) -> NSSegmentedControl? {
        if let s = v as? NSSegmentedControl, s.segmentCount == PanelView.Tab.allCases.count { return s }
        return v.subviews.lazy.compactMap { tabControl(in: $0) }.first
    }

    private func makeWindow(_ title: String, _ rect: CGRect) -> NSWindow {
        let w = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Windowsill · \(mode)")
        label.font = .systemFont(ofSize: 26, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        w.contentView?.addSubview(label)
        if let v = w.contentView {
            NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
                                         label.centerYAnchor.constraint(equalTo: v.centerYAnchor)])
        }
        w.makeKeyAndOrderFront(nil)
        return w
    }
}
