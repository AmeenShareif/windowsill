import SwiftUI
import ServiceManagement

// MARK: - Design tokens

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Each effect carries its own colour through the panel, and its own sky in the header.
struct Look {
    let tint: Color
    let skyTop: Color
    let skyBottom: Color

    static func of(_ e: Effect) -> Look {
        switch e {
        case .snow: return Look(tint: Color(hex: 0x6FB2EA), skyTop: Color(hex: 0x2F4E7C), skyBottom: Color(hex: 0xA7C6E5))
        case .leaves: return Look(tint: Color(hex: 0xD9822B), skyTop: Color(hex: 0x5E4472), skyBottom: Color(hex: 0xF0B16A))
        case .starfall: return Look(tint: Color(hex: 0xD9AE3F), skyTop: Color(hex: 0x0A1230), skyBottom: Color(hex: 0x2B3768))
        case .rain: return Look(tint: Color(hex: 0x5F86B0), skyTop: Color(hex: 0x3B4754), skyBottom: Color(hex: 0x8A99A9))
        case .sakura: return Look(tint: Color(hex: 0xE57AA6), skyTop: Color(hex: 0x86B1E0), skyBottom: Color(hex: 0xF6D5E1))
        case .fireflies: return Look(tint: Color(hex: 0x8DB83A), skyTop: Color(hex: 0x0E1D27), skyBottom: Color(hex: 0x2C4838))
        }
    }
}

private enum Space {
    static let s: CGFloat = 4, m: CGFloat = 8, l: CGFloat = 12, xl: CGFloat = 16
}

// MARK: - Panel

struct PanelView: View {
    enum Tab: String, CaseIterable { case weather = "Weather", christmas = "Christmas", wallpaper = "Wallpaper", settings = "Settings" }

    @ObservedObject private var state = AppState.shared
    @ObservedObject private var updates = Updates.shared
    @State private var tab: Tab

    init(tab: Tab = .weather) { _tab = State(initialValue: tab) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Header(state: state)
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            // Every tab is built once and kept; a click only shows another. Built on each click, a tab's
            // controls held up the falling weather (98 ms for Christmas on a CI Mac with no GPU).
            ZStack(alignment: .topLeading) {
                ForEach(Tab.allCases, id: \.self) { t in
                    let shown = t == tab
                    page(t)
                        .frame(height: shown ? nil : 0, alignment: .top)   // only the shown tab sizes the panel
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                        .disabled(!shown)                                   // out of the keyboard's reach
                        .accessibilityHidden(!shown)
                }
            }
            if let r = updates.newer {
                HStack {
                    Text("Windowsill \(r.version) is out").font(.callout)
                    Spacer()
                    Button("Download") { updates.open() }
                }
            }
        }
        .padding(Space.l)
        .frame(width: 344)
        .tint(Look.of(state.effect).tint)
    }

    @ViewBuilder private func page(_ t: Tab) -> some View {
        switch t {
        case .weather: WeatherTab(state: state)
        case .christmas: ChristmasTab(state: state)
        case .wallpaper: WallpaperTab(state: state)
        case .settings: SettingsTab(state: state)
        }
    }
}

/// The live window ledge with the chosen weather falling on it, the name, and the master switch.
private struct Header: View {
    @ObservedObject var state: AppState

    private var status: String {
        guard state.enabled else { return "Paused" }
        switch state.effect {
        case .snow: return "Snowing"
        case .leaves: return "Leaves falling"
        case .starfall: return "Stars falling"
        case .rain: return "Raining"
        case .sakura: return "Blossom falling"
        case .fireflies: return "Fireflies out"
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SkyPreview(effect: state.effect, running: state.enabled)
                .saturation(state.enabled ? 1 : 0.25)
            VStack(alignment: .leading, spacing: 0) {
                Text("Windowsill").font(.system(.title2, design: .serif).weight(.semibold))
                Text(status).font(.callout)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
            .padding(.leading, Space.l)
            .padding(.bottom, 20)
        }
        .frame(height: 104)
        .overlay(alignment: .topTrailing) {
            Toggle("Effects on", isOn: $state.enabled)
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
                .padding(.horizontal, Space.m).padding(.vertical, Space.s)
                .modifier(FloatingControl())
                .padding(Space.m)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// A control floating over the live scene: Liquid Glass where the system has it, a material elsewhere.
private struct FloatingControl: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
        #else
        content.background(.ultraThinMaterial, in: Capsule())
        #endif
    }
}

/// A choice in a small grid. Unselected choices carry no fill, so the selection is the only shape.
private struct Choice<Content: View>: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.s) {
                content().frame(maxWidth: .infinity, minHeight: 30)
                Text(title).font(.caption).lineLimit(1)
            }
            .padding(.vertical, Space.m).padding(.horizontal, Space.s)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.tint.opacity(0.2))
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.tint, lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4) // a plain button does not dim itself when disabled
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private let threeColumns = Array(repeating: GridItem(.flexible(), spacing: Space.s), count: 3)

// MARK: - Tabs

private struct WeatherTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            LazyVGrid(columns: threeColumns, spacing: Space.s) {
                ForEach(Effect.allCases) { e in
                    Choice(title: e.title, selected: state.effect == e, action: { state.effect = e }) {
                        Image(systemName: e.symbol).font(.title2)
                            .foregroundStyle(state.effect == e ? AnyShapeStyle(Look.of(e).tint) : AnyShapeStyle(.secondary))
                    }
                }
            }
            Text(state.effect.blurb).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Amount") { Slider(value: $state.intensity, in: 0.2...2) }
            LabeledContent("Wind") {
                HStack(spacing: Space.s) {
                    Image(systemName: "arrow.left").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $state.wind, in: -1...1)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Opacity") { Slider(value: $state.opacity, in: 0.25...1) }
            Toggle("Fall behind windows", isOn: $state.behindWindows)
            if state.effect == .snow { Toggle("Let settled snow melt", isOn: $state.melt) }
            if let note = state.powerNote {
                Label("\(note), so effects run lighter", systemImage: "leaf")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ChristmasTab: View {
    @ObservedObject var state: AppState
    @State private var clearArmed = false
    @State private var snowNote: String?           // why no snowman could be rolled just now
    private var engine: Engine { Engine.shared }

    private func icon(_ t: Tool) -> String {
        switch t {
        case .move: return "hand.point.up.left.fill"
        case .bauble: return "circle.fill"
        case .lights: return "lightbulb.fill"
        case .cane: return "line.diagonal"
        case .star: return "star.fill"
        case .remove: return "trash"
        }
    }

    private var hint: String {
        switch state.tool {
        case .move: return "Drag trees, snowmen and presents around. Click a present to open it."
        case .remove: return "Click an ornament to take it off, or a tree, snowman or present to remove it."
        case .star: return "Click a tree to put a star on top."
        case .lights: return "Click a tree to hang a string of lights."
        case .cane: return "Click a tree to hang a candy cane."
        case .bauble: return "Click a tree to hang a bauble."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Toggle("Show decorations", isOn: $state.showDecor)
            HStack {
                Button { engine.growTree() } label: {
                    Label("Grow a tree (\(state.decor.trees.count) of 3)", systemImage: "tree.fill")
                }
                .disabled(state.decor.trees.count >= 3)
                Button {
                    snowNote = engine.rollSnowman()
                    if snowNote != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { snowNote = nil } }
                } label: { Label("Roll a snowman", systemImage: "figure.wave") }
                    .disabled(state.decor.snowmen.count >= 6)
            }
            .disabled(!state.showDecor)
            if let note = snowNote {
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(columns: threeColumns, spacing: Space.s) {
                ForEach(Tool.allCases) { t in
                    Choice(title: t.title, selected: state.tool == t, action: { state.tool = t }) {
                        Image(systemName: icon(t)).font(.title3)
                    }
                }
            }
            .disabled(!state.showDecor)
            Text(state.showDecor ? hint : "Turn on decorations to grow trees, roll snowmen and meet the visitors.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("Visitors").font(.headline)
            Toggle("Santa flies over and drops presents", isOn: $state.santaVisits)
            Toggle("The gift train delivers to your trees", isOn: $state.trainVisits)
            Toggle("A Yeti tries to steal your snowmen", isOn: $state.yetiVisits)
            HStack {
                Button("Call Santa") { engine.mainScene?.callSanta() }
                Button("Send the train") { engine.mainScene?.sendTrain() }
                    .disabled(state.decor.trees.isEmpty)
                    .help("The train delivers to a tree: grow one first.")
                Button("Summon the Yeti") { engine.mainScene?.summonYeti() }
            }
            .controlSize(.small)
            .disabled(!state.showDecor)

            Button(clearArmed ? "Click again to clear everything" : "Clear all decorations", role: .destructive) {
                if clearArmed {
                    engine.clearDecor()
                    clearArmed = false
                } else {
                    clearArmed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { clearArmed = false }
                }
            }
            .controlSize(.small)
            .disabled(state.decor.trees.isEmpty && state.decor.snowmen.isEmpty && state.decor.presents.isEmpty)
        }
    }
}

private struct WallpaperTab: View {
    @ObservedObject var state: AppState
    @ObservedObject private var walls = WallpaperManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            LazyVGrid(columns: threeColumns, spacing: Space.s) {
                Choice(title: "Your own", selected: state.theme == nil, action: { state.theme = nil }) {
                    Image(systemName: "photo").font(.title2)
                }
                ForEach(Theme.allCases) { t in
                    Choice(title: t.title, selected: state.theme == t, action: { state.theme = t }) {
                        thumb(t)
                    }
                }
            }
            Toggle("Follow the time of day", isOn: $state.dayNight)
            if state.dayNight {
                Text("Showing the \(TimeOfDay.now().light.rawValue) painting now. It changes at sunrise and nightfall.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Light", selection: Binding(get: { state.fixedTime.light },
                                                   set: { state.fixedTime = Self.representative[$0] ?? .midday })) {
                    ForEach(Light.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if let note = state.wallpaperNote {
                Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { walls.loadThumbs() }
        .onChange(of: state.fixedTime) { walls.loadThumbs() }
        .onChange(of: state.dayNight) { walls.loadThumbs() }
    }

    private static let representative: [Light: TimeOfDay] = [.day: .midday, .evening: .sunset, .night: .night]

    @ViewBuilder private func thumb(_ t: Theme) -> some View {
        if let img = walls.thumbs[t] {
            Image(nsImage: img).resizable().aspectRatio(16.0 / 10, contentMode: .fill)
                .frame(height: 46).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary).frame(height: 46)
        }
    }
}

private struct SettingsTab: View {
    @ObservedObject var state: AppState
    /// Asking macOS for the login item is a round trip to a system service, and an @State initial value is
    /// evaluated every time the panel redraws: ask once off the main thread, remember the answer.
    private static var knownAtLogin = false
    @State private var atLogin = SettingsTab.knownAtLogin
    @State private var loginError: String?

    private func setAtLogin(_ on: Bool) {
        atLogin = on
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS didn't allow it: \(error.localizedDescription)"
            atLogin = SMAppService.mainApp.status == .enabled
        }
        Self.knownAtLogin = atLogin
    }

    static let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String
        return "Version \(short)" + (build.map { " (\($0))" } ?? "")
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Toggle("Open at login", isOn: Binding(get: { atLogin }, set: setAtLogin))
                .task {
                    let on = await Task.detached { SMAppService.mainApp.status == .enabled }.value
                    Self.knownAtLogin = on
                    atLogin = on
                }
            if let e = loginError { Text(e).font(.caption).foregroundStyle(.red) }
            Toggle("Show on every display", isOn: $state.allScreens)
            Toggle("Keep going over full-screen apps", isOn: $state.overFullScreen)
            Toggle("Show in screenshots and screen sharing", isOn: $state.inScreenshots)
            Toggle("Check for new versions", isOn: $state.checkUpdates)
                .onChange(of: state.checkUpdates) { Updates.shared.check() }
            LabeledContent("Power") {
                Text(state.powerNote.map { "\($0): half density, 30 fps" } ?? "Full quality, 60 fps")
            }
            Text((state.overFullScreen ? "Effects pause" : "Effects pause under full-screen apps,")
                 + " while the display sleeps and while the screen is locked. Windowsill collects nothing. "
                 + (state.checkUpdates ? "Its only connection is a daily look at GitHub for a new version."
                                       : "It makes no network connections."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(Self.version).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit Windowsill") { NSApp.terminate(nil) }
            }
        }
    }
}

// MARK: - Live header scene

private struct SkyPreview: View {
    let effect: Effect
    let running: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let still = !running || reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { tl in
            Canvas { ctx, size in
                SkyPainter.paint(&ctx, size, effect, still ? 6 : tl.date.timeIntervalSinceReferenceDate)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Draws the header from the clock alone, so it needs no state and a still frame is free.
enum SkyPainter {
    static let ledge: CGFloat = 14

    /// A stable pseudo-random number in 0..<1 for particle `i`, channel `k`.
    static func rand(_ i: Int, _ k: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43758.5453
        return x - floor(x)
    }

    static func paint(_ ctx: inout GraphicsContext, _ size: CGSize, _ e: Effect, _ t: Double) {
        let look = Look.of(e), w = size.width, h = size.height, floor = h - ledge
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [look.skyTop, look.skyBottom]),
                                       startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))

        /// x drifting with a sway, wrapped to the width; y falling from above the top to the ledge.
        func fall(_ i: Int, speed: ClosedRange<Double>, sway: Double) -> CGPoint {
            let v = speed.lowerBound + rand(i, 2) * (speed.upperBound - speed.lowerBound)
            let y = (t * v + rand(i, 3) * Double(floor + 20)).truncatingRemainder(dividingBy: Double(floor + 20)) - 10
            let x = rand(i, 1) * Double(w) + sin(t * 0.9 + rand(i, 4) * 6.3) * sway + t * 4
            return CGPoint(x: x.truncatingRemainder(dividingBy: Double(w) + 20) - 10, y: y)
        }

        switch e {
        case .snow:
            for i in 0..<70 {
                let p = fall(i, speed: 14...34, sway: 6), r = 1 + rand(i, 5) * 1.6
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(.white.opacity(0.55 + rand(i, 6) * 0.4)))
            }
        case .leaves, .sakura:
            let colors: [Color] = e == .leaves
                ? [Color(hex: 0xE0892B), Color(hex: 0xB9471F), Color(hex: 0xE8B53A)]
                : [Color(hex: 0xF7B8CF), Color(hex: 0xFBD3E0), Color(hex: 0xEE9DBC)]
            for i in 0..<(e == .leaves ? 14 : 24) {
                let p = fall(i, speed: e == .leaves ? 18...34 : 12...24, sway: e == .leaves ? 14 : 9)
                var leaf = ctx
                leaf.translateBy(x: p.x, y: p.y)
                leaf.rotate(by: .radians(t * (1 + rand(i, 7)) + rand(i, 8) * 6.3))
                let s: CGFloat = e == .leaves ? 4 : 2.8
                leaf.fill(Path(ellipseIn: CGRect(x: -s * 1.6, y: -s, width: s * 3.2, height: s * 2)),
                          with: .color(colors[i % colors.count]))
            }
        case .rain:
            for i in 0..<90 {
                let p = fall(i, speed: 240...320, sway: 0)
                var line = Path()
                line.move(to: p)
                line.addLine(to: CGPoint(x: p.x - 2.5, y: p.y + 9))
                ctx.stroke(line, with: .color(.white.opacity(0.45)), lineWidth: 1)
            }
        case .starfall:
            for i in 0..<45 {
                let x = rand(i, 1) * Double(w), y = rand(i, 2) * Double(floor - 8)
                let a = 0.35 + 0.35 * sin(t * (1 + rand(i, 3) * 2) + rand(i, 4) * 6.3)
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)), with: .color(.white.opacity(a)))
            }
            for i in 0..<3 {
                let phase = (t / 2.8 + rand(i + 50, 1)).truncatingRemainder(dividingBy: 1)
                guard phase < 0.3 else { continue }
                let k = phase / 0.3
                let x0 = Double(w) * (0.45 + rand(i + 50, 2) * 0.5), y0 = Double(floor) * rand(i + 50, 3) * 0.4
                let head = CGPoint(x: x0 - 110 * k, y: y0 + 46 * k)
                var tail = Path()
                tail.move(to: CGPoint(x: head.x + 34, y: head.y - 14))
                tail.addLine(to: head)
                ctx.stroke(tail, with: .linearGradient(Gradient(colors: [.clear, Color(hex: 0xFFF2C4)]),
                                                       startPoint: CGPoint(x: head.x + 34, y: head.y - 14), endPoint: head),
                           lineWidth: 1.6)
            }
        case .fireflies:
            for i in 0..<12 {
                let x = Double(w) * (0.5 + 0.44 * sin(t * 0.3 * (0.5 + rand(i, 1)) + rand(i, 2) * 6.3))
                let y = Double(floor) * (0.5 + 0.36 * sin(t * 0.37 * (0.5 + rand(i, 3)) + rand(i, 4) * 6.3))
                let a = 0.5 + 0.5 * sin(t * 2 + rand(i, 5) * 6.3)
                let c = CGPoint(x: x, y: y)
                ctx.fill(Path(ellipseIn: CGRect(x: x - 9, y: y - 9, width: 18, height: 18)),
                         with: .radialGradient(Gradient(colors: [Color(hex: 0xE4F59A).opacity(a), .clear]),
                                               center: c, startRadius: 0, endRadius: 9))
            }
        }

        // The ledge, and what has settled on it.
        ctx.fill(Path(CGRect(x: 0, y: floor, width: w, height: ledge)), with: .color(Color(hex: 0x1E2328).opacity(0.9)))
        ctx.fill(Path(CGRect(x: 0, y: floor, width: w, height: 1.5)), with: .color(.white.opacity(0.22)))
        switch e {
        case .snow:
            var drift = Path()
            drift.move(to: CGPoint(x: 0, y: floor))
            for x in stride(from: 0, through: Double(w), by: 6) {
                drift.addLine(to: CGPoint(x: x, y: Double(floor) - 3.5 - 2 * sin(x * 0.045) - sin(x * 0.13)))
            }
            drift.addLine(to: CGPoint(x: w, y: floor))
            drift.closeSubpath()
            ctx.fill(drift, with: .color(Color(hex: 0xF4F8FC)))
        case .leaves, .sakura:
            let colors: [Color] = e == .leaves ? [Color(hex: 0xC2581F), Color(hex: 0xE0892B)] : [Color(hex: 0xF7B8CF), Color(hex: 0xEE9DBC)]
            for i in 0..<(e == .leaves ? 7 : 10) {
                let x = rand(i + 90, 1) * Double(w)
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: Double(floor) - 2.5, width: e == .leaves ? 10 : 7, height: 3.5)),
                         with: .color(colors[i % colors.count]))
            }
        default:
            break
        }
    }
}
