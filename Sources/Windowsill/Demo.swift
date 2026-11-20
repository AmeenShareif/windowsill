import AppKit
import ServiceManagement
import SwiftUI

// Release builds leave the scripted demo out altogether, its windows and their words with it; only a CI build
// made with `DEMO=1 scripts/build-app.sh` has it.
#if DEMO
let isDemoRun = CommandLine.arguments.contains("--demo")

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
        case "panel": return 25
        case "daylight": return 37
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
        "christmas": (.winter, .night), "panel": (.winter, .golden), "daylight": (.winter, .midday),
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
        lines.append("pointer \(engine.pointer) view paused \(engine.mainScene?.view?.isPaused ?? true), "
                     + "restarted \(engine.overlays.first?.restarts ?? 0) times for drawing nothing")
        if let p = panelNote { lines.append(p); panelNote = nil }
        lines += WallpaperManager.shared.setCosts.map { "wallpaper \($0)" }
        WallpaperManager.shared.setCosts = []
        if let t = engine.trace, !t.isEmpty {
            lines.append(String(format: "window moves since the last shot, this shot at %.3f:", CACurrentMediaTime()))
            lines += t
            engine.trace = []
        }
        if let scene = engine.mainScene {
            let now = ProcessInfo.processInfo.systemUptime
            let waited = MainWatch.shared.read()
            if lastShot.at > 0 {
                let fps = Double(scene.frameCount - lastShot.frames) / (now - lastShot.at)
                lines.append(String(format: "frames %.1f fps since the last shot, longest gap %.1f ms", fps, scene.longestGap * 1000)
                             + ", main thread answered within \(waited)")
            }
            lastShot = (scene.frameCount, now)
            scene.longestGap = 0
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func start() {
        _ = MainWatch.shared
        let state = AppState.shared
        let christmas = mode == "christmas"
        engine.pileBoost = 8
        engine.trace = []
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
        if mode == "daylight" { daylightTour(f) } else if christmas { christmasTour(f) } else { weatherTour(f) }
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
        at(16.0) { self.brush(along: front) }                                         // leaves and petals scatter
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
        if mode == "fireflies" {
            // Cut off from its window the weather view draws nothing, unpaused, as SpriteKit did on macOS 27
            // (CI, 2026-11-18). The engine's once-a-second check must find it and put it back within 3 s.
            at(29.6) { self.engine.overlays.first?.panel.contentView = nil }
            at(33.2) { self.shot("restarted") }
            at(34.4) { self.shot("resumed") }                                          // its frame rate proves it
        }
    }

    // MARK: - Daylight: a winter's day in New York in half a minute, and the snow on a nudged window sways

    /// Seconds into the run, and the time of day then in minutes after midnight (New York, 2026-12-21:
    /// sunrise 07:17, sunset 16:32). A shot falls on each named key, one in each light the day passes through.
    private static let day: [(at: TimeInterval, minute: Double, shot: String)] = [
        (0, 330, ""), (3, 370, "night"), (6, 420, "dawn"), (9, 450, "sunrise"), (12, 510, "morning"),
        (16, 660, "midday"), (21, 720, ""), (25, 910, "golden"), (28, 970, "sunset"), (31, 1005, "dusk"),
        (34, 1060, "nightfall"),
    ]

    private func daylightTour(_ f: CGRect) {
        guard let front = windows.last else { return }
        AppState.shared.dayNight = true
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York") ?? .current
        let midnight = cal.date(from: DateComponents(year: 2026, month: 12, day: 21)) ?? Date()
        let t0 = Date(), keys = Self.day
        Sun.shared.pin(.init(lat: 40.71, lon: -74.01, estimated: false)) {
            let s = Date().timeIntervalSince(t0)
            let i = keys.lastIndex { $0.at <= s } ?? 0, j = min(i + 1, keys.count - 1)
            let k = j > i ? min(1, (s - keys[i].at) / (keys[j].at - keys[i].at)) : 0
            return midnight.addingTimeInterval((keys[i].minute + (keys[j].minute - keys[i].minute) * k) * 60)
        }
        // The painting follows the light, which on this clock changes every few seconds, not every few hours.
        if ProcessInfo.processInfo.environment["CI"] != nil {
            let paint = Timer(timeInterval: 0.5, repeats: true) { _ in WallpaperManager.shared.apply() }
            RunLoop.main.add(paint, forMode: .common)
            timers.append(paint)
        }
        for key in keys where !key.shot.isEmpty { at(key.at) { self.shot(key.shot) } }
        // At noon, nudges: the snow leans back as the window sets off, forward as it stops, and settles.
        at(16.4) { self.glide(to: { self.titleBar(front) }, over: 0.6) }
        at(17.2) { self.drag(front, by: CGVector(dx: 45, dy: 0), over: 0.4) }
        at(17.4) { self.shot("nudge") }
        at(18.4) { self.drag(front, by: CGVector(dx: -45, dy: 0), over: 0.25, press: false) }
        at(18.7) { self.shot("settle") }
        at(19.6) { self.drag(front, by: CGVector(dx: 0, dy: 30), over: 0.3, press: false) }
        at(19.95) { self.shot("lift") }
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
        at(12.9) { self.shot("santa") }                                               // his team mid-screen (230 pt/s)
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
        // A present left on a display since unplugged: after the 10 s grace it pops in on this screen's floor.
        var stray: UUID?
        at(40.0) {
            self.engine.addPresent(at: CGPoint(x: f.maxX + 300, y: f.midY), anchored: false)
            stray = self.engine.decor.presents.last?.id
        }
        at(54.0) {
            let spot = self.engine.decor.presents.first(where: { $0.id == stray }).map { "\(Int($0.x)),\(Int($0.y))" } ?? "gone"
            print("demo rehome: the stray present is at \(spot); screen \(f)")
            self.shot("rehomed")
        }
        at(58.0) { self.shot("end") }
    }

    // MARK: - The scripted pointer

    /// Moves the drawn pointer to a (possibly moving) target; `step` sees each position on the way. It
    /// moves once a frame, as a hand does: on its own 60 Hz timer it fired 0-80 ms apart on CI, and the
    /// windows it dragged jumped 0-53 pt a frame (2026-11-19).
    private func glide(to target: @escaping () -> CGPoint, over d: TimeInterval, curve: Curve = .smooth,
                       step: ((CGPoint) -> Void)? = nil, then: (() -> Void)? = nil) {
        let engine = engine
        let a = engine.pointerOverride ?? target()
        let t0 = CACurrentMediaTime()
        engine.everyFrame.append {
            let k = CGFloat(min(1, (CACurrentMediaTime() - t0) / max(d, 0.001)))
            let e = curve == .smooth ? k * k * (3 - 2 * k) : k * k
            let b = target()
            let q = CGPoint(x: a.x + (b.x - a.x) * e, y: a.y + (b.y - a.y) * e)
            engine.pointerOverride = q
            step?(q)
            if k >= 1 { then?() }
            return k < 1
        }
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
        // On the tree's side toward the middle of the screen: on its far side it sat out past the Dock's end.
        let mid = engine.mainScene?.screenRect.midX ?? 0
        for tree in engine.decor.trees {
            engine.addPresent(at: CGPoint(x: tree.x + (tree.x < mid ? 58 : -58), y: tree.y), anchored: true)
        }
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

    /// The real menu bar panel, opened by clicking the snowflake as a person does: every tab, light then dark.
    /// Then it is closed with a second click and Windowsill opened again, as from Finder, which shows the same
    /// panel in a window: what someone whose menu bar has hidden the snowflake gets.
    private func showPanel(_ f: CGRect) {
        func ms(since t: CFTimeInterval) -> String { String(format: "%.1f ms", (CACurrentMediaTime() - t) * 1000) }
        func box(_ r: CGRect?) -> String {
            r.map { "x \(Int($0.minX))...\(Int($0.maxX)), y \(Int($0.minY))...\(Int($0.maxY))" } ?? "nowhere"
        }
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

        let steps: [(PanelView.Tab, Effect, Bool)] = [
            (.weather, .snow, false), (.christmas, .snow, false), (.wallpaper, .snow, false), (.settings, .snow, false),
            (.weather, .snow, true), (.christmas, .snow, true), (.wallpaper, .snow, true), (.settings, .snow, true),
        ]
        // One panel for the whole demo, its tabs changed through its own segmented control as a click does.
        var host: NSView?
        // The panel opens once the weather has run a moment, as a click on the menu bar icon finds it. Opened
        // at launch, its gap also held the weather's own first frames, so launch is read on its own first.
        var openNote = ""
        var clicked = 0.0
        at(0.6) {
            let launch = "\(AppDelegate.launchNote); longest gap at launch \(gap())"
            WallpaperManager.shared.loadThumbs()
            guard let b = Self.statusButton() else {
                openNote = "\(launch); NO MENU BAR ITEM, opened as from Finder instead"
                _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
                return
            }
            clicked = CACurrentMediaTime()
            b.performClick(nil)
            openNote = "\(launch); snowflake at \(box(b.window?.frame)) clicked in \(ms(since: clicked))"
        }
        // The panel takes its time to appear, so it is looked for until it does. Should the click not open it,
        // a mouse press on the snowflake is tried, then opening Windowsill again, so the tabs are still shown.
        for k in 0..<36 {
            at(0.65 + Double(k) * 0.05) {
                guard host == nil, let w = Self.panelWindow() else { return }
                host = w.contentView
                openNote += "; panel at \(box(w.frame)) on a screen \(Int(f.width)) wide \(ms(since: clicked)) after the click; "
                    + "longest gap over opening it \(gap())"
            }
        }
        at(1.5) {
            guard host == nil, let b = Self.statusButton() else { return }
            openNote += "; NO PANEL 0.9 s after the click, so the snowflake was pressed "
                + (Self.press(b) ? "with the real mouse" : "by an event sent to it (the app may not post real mouse events)")
        }
        at(2.45) {
            guard host == nil else { return }
            openNote += "; NO PANEL after the press either, so it was opened as from Finder"
            _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
            host = Self.panelWindow()?.contentView
        }

        // Closed by a click on the desktop, as a menu closes, then Windowsill opened again from Finder. Where the
        // app may not post real mouse events, or the click left it open, a second click on the snowflake closes it.
        var pressedShut = " by a click on the desktop"
        at(20.5) { if !Self.clickDesktop(f) { pressedShut = " by a second click on the snowflake" } }
        at(20.8) {
            guard Self.panelWindow() != nil else { return }
            if pressedShut.hasSuffix("desktop") { pressedShut += " that did NOT close it, then a click on the snowflake" }
            Self.statusButton()?.performClick(nil)
        }
        var reopenNote = ""
        at(21.2) {
            let open = Self.panelWindow() != nil
            _ = gap()
            _ = MainWatch.shared.read()
            let asked = CACurrentMediaTime()
            let answer = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
            // Opening it again builds the same view: a gap as long as the first one's is the view's own cost.
            reopenNote = "menu bar panel \(open ? "STILL OPEN" : "closed")\(pressedShut); reopen "
                + (answer == nil ? "NOT HANDLED: the app delegate does not answer it" : "handled")
                + " in \(ms(since: asked))"
        }
        at(21.9) {
            // The window reopening makes: titled, unlike the menu bar's own panel.
            let w = NSApp.windows.first { $0.isVisible && $0.title == "Windowsill" && $0.styleMask.contains(.titled) }
            self.panelNote = "panel \(reopenNote), longest gap over reopening it \(gap()), main thread answered within "
                + "\(MainWatch.shared.read()); reopened at \(box(w?.frame)), "
                + (w?.isKeyWindow == true ? "key" : "NOT KEY, so its controls draw inactive")
                + (NSApp.isActive ? ", app active" : ", app not active")
            self.shot("reopened")
        }
        // Last, the overlay stepped out of screenshots: this one should show the desktop and the panel, no weather.
        at(22.3) { state.inScreenshots = false }
        at(23.3) { self.shot("hidden") }
        // "Your own" after a painting must give the runner its own desktop back, not leave the painting up.
        at(23.6) { state.theme = nil }
        at(24.4) {
            // Only the shot judges it: macOS 27 still names the painting here while it shows the runner's own.
            let url = NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            self.panelNote = "wallpaper after Your own: macOS names \(url?.lastPathComponent ?? "none"); the shot shows which"
            self.shot("own")
        }
        for (i, step) in steps.enumerated() {
            let t0 = 3.0 + Double(i) * 2.2
            var note: [String] = []
            // Light or dark, then the weather, then the tab, each on its own, so each hitch has one cause.
            at(t0 - 0.5) {
                if i == 0 { note.append(openNote) }
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
                MenuPanel.shared.trace.removeAll()
                if let seg = (host ?? Self.panelWindow()?.contentView).flatMap(Self.tabControl(in:)),
                   let n = PanelView.Tab.allCases.firstIndex(of: step.0) {
                    seg.selectedSegment = n
                    _ = seg.sendAction(seg.action, to: seg.target)
                    note.append("tab clicked \(ms(since: t))")
                } else {
                    note.append("tab control not found")
                }
            }
            // The new tab is built and drawn on the next pass of the run loop, and the panel resized to it.
            at(t0 + 0.13) { note.append("longest gap over building the tab \(gap())") }
            // The panel's height through the change: eased, it passes through heights between the two tabs'.
            var heights: [Int] = []
            for dt in [0.0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.45] {
                at(t0 + 0.02 + dt) { heights.append(Int(Self.panelWindow()?.frame.height ?? 0)) }
            }
            at(t0 + 0.6) {
                note.append("longest gap over resizing the panel \(gap())")
                note.append("heights over it \(heights.map(String.init).joined(separator: " "))")
                note.append("fit \(MenuPanel.shared.trace.joined(separator: " "))")
            }
            at(t0 + 1.6) {
                note.append("panel at \(box(Self.panelWindow()?.frame))")
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

    /// The snowflake in the menu bar: the button of the app's one status item.
    private static func statusButton() -> NSStatusBarButton? {
        func find(_ v: NSView) -> NSStatusBarButton? {
            if let b = v as? NSStatusBarButton { return b }
            return v.subviews.lazy.compactMap(find).first
        }
        return NSApp.windows.lazy.compactMap { w in (w.contentView?.superview ?? w.contentView).flatMap(find) }.first
    }

    /// A mouse press on the snowflake: with the real mouse where the app may post events (as a person's click
    /// arrives), else as the window server would deliver one, the release queued first so a button that
    /// tracks the mouse after the press finds it. Returns whether the real mouse was used.
    @discardableResult
    private static func press(_ b: NSStatusBarButton) -> Bool {
        guard let w = b.window else { return false }
        if CGPreflightPostEventAccess(), let primary = NSScreen.screens.first {
            let r = w.convertToScreen(b.convert(b.bounds, to: nil))
            let q = CGPoint(x: r.midX, y: primary.frame.height - r.midY)   // Quartz: y down from the top
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: q, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
            }
            return true
        }
        let p = b.convert(NSPoint(x: b.bounds.midX, y: b.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: type == .leftMouseDown ? 1 : 0)
        }
        if let up = event(.leftMouseUp) { NSApp.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown) { w.sendEvent(down) }
        return false
    }

    /// A click with the real mouse on the desktop, left of centre and away from the panel and the Dock, as a
    /// person dismisses a menu. Returns false where the app may not post real mouse events.
    private static func clickDesktop(_ f: CGRect) -> Bool {
        guard CGPreflightPostEventAccess(), let primary = NSScreen.screens.first else { return false }
        let q = CGPoint(x: f.minX + 120, y: primary.frame.height - f.midY)   // Quartz: y down from the top
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: q, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        return true
    }

    /// The open panel, from the menu bar or reopened: the visible window that holds the tab picker. The menu bar
    /// panel fading out after a close counts as closed.
    private static func panelWindow() -> NSWindow? {
        NSApp.windows.first { w in
            w.isVisible && !(w === MenuPanel.shared.panel && MenuPanel.shared.closing)
                && w.contentView.flatMap(tabControl(in:)) != nil
        }
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

/// The longest the main thread kept a ping from another thread waiting since the last read. A long frame gap
/// with a short wait here is macOS not drawing (the display link starved), not this app holding its thread.
final class MainWatch {
    static let shared = MainWatch()
    private let lock = NSLock()
    private var worst: CFTimeInterval = 0

    private init() {
        Thread.detachNewThread { [unowned self] in
            while true {
                let sent = CACurrentMediaTime()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let waited = CACurrentMediaTime() - sent
                self.lock.lock(); self.worst = max(self.worst, waited); self.lock.unlock()
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    /// The worst wait since the last read, then starts over.
    func read() -> String {
        lock.lock()
        defer { worst = 0; lock.unlock() }
        return String(format: "%.1f ms", worst * 1000)
    }
}
#endif
