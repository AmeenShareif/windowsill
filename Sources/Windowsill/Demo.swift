import AppKit

/// `--demo <effect|christmas> [--shots <dir>]`: a scripted run for CI screenshots.
/// The app asks for a screenshot by dropping `<dir>/<name>.req`; scripts/demo-shots.sh takes it.
enum Demo {
    static func parse(_ args: [String]) -> String? {
        guard let i = args.firstIndex(of: "--demo"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

final class DemoRun {
    private let mode: String
    private let shots: URL?
    private var windows: [NSWindow] = []
    private var timers: [Timer] = []
    private var flingStep = 0
    private var flingStart = CGPoint.zero

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
    }

    func start() {
        let state = AppState.shared, engine = Engine.shared
        let christmas = mode == "christmas"
        engine.pileBoost = 8
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
        at(1.0) { print("demo \(self.mode): dock \(engine.snap.dock.map { "\($0)" } ?? "not found"), floor \(engine.mainScene?.floorY ?? -1)") }
        if mode == "panel" { return showPanel(f) }
        windows = [
            makeWindow("Notes", CGRect(x: f.minX + f.width * 0.08, y: f.minY + f.height * 0.16,
                                       width: f.width * 0.42, height: f.height * 0.44)),
            makeWindow("Windowsill demo", CGRect(x: f.minX + f.width * 0.4, y: f.minY + f.height * 0.3,
                                                 width: f.width * 0.4, height: f.height * 0.38)),
        ]
        NSApp.activate()

        if christmas {
            at(0.6) { engine.growTree(); engine.growTree() }
            at(1.4) { self.decorate() }
            at(2.0) {
                engine.rollSnowman(onWindow: self.windows.last?.windowNumber)
                engine.rollSnowman(onWindow: self.windows.first?.windowNumber)
            }
            at(3.0) { engine.mainScene?.callSanta() }
            at(9.0) { engine.mainScene?.sendTrain() }
            at(16.0) { engine.mainScene?.summonYeti() }
            for t in [5.0, 8.0, 12.0, 15.0, 19.0, 22.0, 26.0] { at(t) { self.shot("t\(Int(t))") } }
            at(30) { NSApp.terminate(nil) }
        } else {
            at(11.0) { self.shot("still") }
            at(11.5) { self.fling() }
            at(12.2) { self.shot("fling") }
            at(14.0) { NSApp.terminate(nil) }
        }
    }

    /// The menu bar panel in an ordinary window, every tab, light then dark.
    private func showPanel(_ f: CGRect) {
        let state = AppState.shared
        state.showDecor = false
        state.dayNight = false
        state.fixedTime = .golden
        let host = NSHostingView(rootView: PanelView())
        let w = NSWindow(contentRect: CGRect(x: f.midX - 172, y: f.maxY - 640, width: 344, height: 600),
                         styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.makeKeyAndOrderFront(nil)
        windows = [w]
        NSApp.activate()

        let steps: [(PanelView.Tab, Effect, Bool)] = [
            (.weather, .snow, false), (.christmas, .snow, false), (.wallpaper, .leaves, false), (.settings, .sakura, false),
            (.weather, .fireflies, true), (.christmas, .starfall, true), (.wallpaper, .rain, true),
        ]
        for (i, step) in steps.enumerated() {
            let t0 = 1.5 + Double(i) * 2.2
            at(t0) {
                NSApp.appearance = NSAppearance(named: step.2 ? .darkAqua : .aqua)
                state.effect = step.1
                host.rootView = PanelView(tab: step.0)
                w.setContentSize(host.fittingSize)
                w.setFrameTopLeftPoint(CGPoint(x: f.midX - 172, y: f.maxY - 20))
                WallpaperManager.shared.loadThumbs()
            }
            at(t0 + 1.6) { self.shot("\(step.2 ? "dark" : "light")-\(step.0.rawValue.lowercased())") }
        }
        at(1.5 + Double(steps.count) * 2.2 + 0.5) { NSApp.terminate(nil) }
    }

    private func makeWindow(_ title: String, _ rect: CGRect) -> NSWindow {
        let w = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
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

    private func decorate() {
        let engine = Engine.shared
        let baubles: [(CGFloat, CGFloat)] = [(-30, 60), (25, 85), (-12, 130), (18, 40), (0, 165), (-36, 30)]
        for tree in engine.decor.trees {
            engine.addOrnament(Ornament(kind: .star, x: 0, y: TreeShape.apex.y, color: 0), to: tree.id)
            engine.addOrnament(Ornament(kind: .lights, x: 0, y: 112, color: 0), to: tree.id)
            engine.addOrnament(Ornament(kind: .lights, x: 0, y: 62, color: 0), to: tree.id)
            engine.addOrnament(Ornament(kind: .cane, x: 34, y: 50, color: 0), to: tree.id)
            for (i, b) in baubles.enumerated() {
                engine.addOrnament(Ornament(kind: .bauble, x: b.0, y: b.1, color: i % Ornament.palette.count), to: tree.id)
            }
            engine.addPresent(at: CGPoint(x: tree.x + 58, y: tree.y), anchored: true)
        }
    }

    /// Throws the front window up and to the right, the way a person flicks it.
    private func fling() {
        guard let w = windows.last else { return }
        flingStart = w.frame.origin
        flingStep = 0
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.flingStep += 1
            let k = CGFloat(self.flingStep) / 18
            w.setFrameOrigin(CGPoint(x: self.flingStart.x + 280 * k, y: self.flingStart.y + 150 * k))
            if self.flingStep >= 18 { t.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }
}
