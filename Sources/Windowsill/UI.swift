import SwiftUI
import ServiceManagement

// MARK: - Design tokens

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// Each effect's sky in the header tile. The controls use the system accent colour, as Control Center does.
struct Look {
    let skyTop: Color
    let skyBottom: Color

    static func of(_ e: Effect) -> Look {
        switch e {
        case .snow: return Look(skyTop: Color(hex: 0x2F4E7C), skyBottom: Color(hex: 0xA7C6E5))
        case .leaves: return Look(skyTop: Color(hex: 0x5E4472), skyBottom: Color(hex: 0xF0B16A))
        case .starfall: return Look(skyTop: Color(hex: 0x0A1230), skyBottom: Color(hex: 0x2B3768))
        case .rain: return Look(skyTop: Color(hex: 0x3B4754), skyBottom: Color(hex: 0x8A99A9))
        case .sakura: return Look(skyTop: Color(hex: 0x86B1E0), skyBottom: Color(hex: 0xF6D5E1))
        case .fireflies: return Look(skyTop: Color(hex: 0x0E1D27), skyBottom: Color(hex: 0x2C4838))
        }
    }
}

private enum Space {
    static let s: CGFloat = 4, m: CGFloat = 8, l: CGFloat = 12, xl: CGFloat = 16
}

/// A Control Center module: a rounded platter a shade lighter than the panel's material, in light and in dark,
/// with a hairline edge when the user asks for more contrast.
private struct Module: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .padding(Space.l - 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(scheme == .dark ? 0.08 : 0.6), in: shape)
            .overlay { if contrast == .increased { shape.strokeBorder(.separator) } }
    }
}

private extension View {
    func module() -> some View { modifier(Module()) }
}

/// A setting laid out as System Settings and Control Center do: the words leading, a mini switch trailing.
private func switchRow(_ title: String, _ on: Binding<Bool>) -> some View {
    HStack(spacing: Space.m) {
        Text(title).accessibilityHidden(true)   // the switch carries the same words
        Spacer(minLength: 0)
        Toggle(title, isOn: on).toggleStyle(.switch).controlSize(.mini).labelsHidden()
    }
}

/// A labelled slider with a small symbol at each end, the least on the leading side.
private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                       low: String, high: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline).foregroundStyle(.secondary).accessibilityHidden(true)
        HStack(spacing: Space.m) {
            Image(systemName: low).frame(width: 16).accessibilityHidden(true)
            Slider(value: value, in: range).accessibilityLabel(title)
            Image(systemName: high).frame(width: 16).accessibilityHidden(true)
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Panel

/// The panel as one view: the reopened window's and Command-comma's. The menu bar's own is in pieces (MenuPanel).
struct PanelView: View {
    enum Tab: String, CaseIterable { case weather = "Weather", christmas = "Christmas", wallpaper = "Wallpaper", settings = "Settings" }
    static let width: CGFloat = 344

    @ObservedObject private var state = AppState.shared
    @ObservedObject private var updates = Updates.shared
    @ObservedObject private var warmth = Warmth.shared
    @State private var tab = Tab.weather

    var body: some View {
        let _ = bodyRan("panel")
        VStack(alignment: .leading, spacing: Space.m) {
            PanelTop(tab: $tab)
            // Every tab is built once and kept; a click only shows another. Built on each click, a tab's
            // controls held up the falling weather (98 ms for Christmas on a CI Mac with no GPU).
            Pages(shown: Tab.allCases.firstIndex(of: tab) ?? 0) {
                ForEach(Tab.allCases, id: \.self) { t in
                    let shown = t == tab
                    Self.page(t, state)
                        // Shown at once, as a Mac's tabs are. A cross-fade made new layers for both tabs at each
                        // click (55-86 ms on CI, run 45226029990). Hidden tabs are drawn at 1% while Warmth is on.
                        .opacity(shown ? 1 : warmth.on ? 0.01 : 0)
                        .allowsHitTesting(shown)
                        .disabled(!shown)                                   // out of the keyboard's reach
                        .accessibilityHidden(!shown)
                }
            }
            Self.notice(updates)
        }
        .padding(Space.l)
        .frame(width: Self.width)
        .animation(.snappy(duration: 0.25), value: updates.newer?.version)
    }

    @ViewBuilder static func page(_ t: Tab, _ state: AppState) -> some View {
        switch t {
        case .weather: WeatherTab(state: state)
        case .christmas: ChristmasTab(state: state)
        case .wallpaper: WallpaperTab(state: state)
        case .settings: SettingsTab(state: state)
        }
    }

    /// A newer Windowsill, when there is one, under the tab.
    @ViewBuilder static func notice(_ updates: Updates) -> some View {
        if let r = updates.newer {
            HStack {
                Label("Windowsill \(r.version) is out", systemImage: "arrow.down.circle")
                Spacer()
                Button("Download") { updates.open() }.buttonStyle(.borderedProminent).controlSize(.small)
            }
            .module()
            .transition(.opacity)
        }
    }

    /// The menu bar panel's pieces, each in a hosting view of its own (MenuPanel): the top, then each tab with the
    /// notice under it, padded so that stacked they lay out as this view does.
    static func top(_ tab: Binding<Tab>) -> some View { PanelTop(tab: tab).padding([.horizontal, .top], Space.l) }
    static func piece(_ t: Tab) -> some View { PanelPage(tab: t).padding(.top, Space.m).padding([.horizontal, .bottom], Space.l) }
}

/// The header, then the tab picker.
private struct PanelTop: View {
    @Binding var tab: PanelView.Tab

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Header(state: AppState.shared)
            Picker("Section", selection: $tab) {
                ForEach(PanelView.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }
}

/// One tab and the notice under it.
private struct PanelPage: View {
    let tab: PanelView.Tab
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            PanelView.page(tab, AppState.shared)
            PanelView.notice(updates)
        }
        .animation(.snappy(duration: 0.25), value: updates.newer?.version)
    }
}

/// While on, the panel's hidden tabs are drawn too, at 1%, where nobody sees them. A tab shown for the first time
/// in a light or dark look drew everything as it was clicked: the panel stood still 90 to 180 ms before it
/// resized (CI run 45217528066). On while the reopened window is drawn at launch (MenuPanel.predraw).
final class Warmth: ObservableObject {
    static let shared = Warmth()
    @Published var on = false
}

/// Every tab laid out at its own full size, always, the panel taking the shown one's: a click changes which size
/// counts and no tab is measured again. Hidden by a frame of height 0, a tab was laid out squeezed, then in full
/// at the click that showed it.
private struct Pages: Layout {
    let shown: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.indices.contains(shown) else { return .zero }
        return subviews[shown].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let each = ProposedViewSize(width: bounds.width, height: nil)
        for s in subviews { s.place(at: bounds.origin, anchor: .topLeading, proposal: each) }
    }
}

/// Laid out like Control Center's Now Playing: the live ledge with the chosen weather falling on it as the
/// artwork, the name and what it is doing, and the master switch.
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
        let _ = bodyRan("header")
        HStack(spacing: Space.l) {
            SkyPreview(effect: state.effect, running: state.enabled)
                .saturation(state.enabled ? 1 : 0.25)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Windowsill").font(.headline)
                Text(status).font(.subheadline).foregroundStyle(.secondary).contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            Toggle("Effects on", isOn: $state.enabled).toggleStyle(.switch).labelsHidden()
        }
        .module()
        .animation(.easeInOut(duration: 0.25), value: state.enabled)   // the tile greys and the words change together
    }
}

/// A plain button that gives a little under the pointer and springs back, as Control Center's buttons do.
private struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// One of a few choices drawn as Control Center draws its buttons: a round button, filled with the accent
/// colour and its symbol turned white when chosen, so the choice shows by shape and weight as well as colour.
private struct RoundChoice: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    @State private var presses = 0

    var body: some View {
        Button {
            presses += 1
            action()
        } label: {
            VStack(spacing: Space.s + 1) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .symbolEffect(.bounce, value: presses)   // the symbol answers the click
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(selected ? AnyShapeStyle(Color.accentColor)
                                              : AnyShapeStyle(hovering && isEnabled ? HierarchicalShapeStyle.tertiary : .quaternary)))
                Text(title).font(.caption).foregroundStyle(selected ? .primary : .secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .opacity(isEnabled ? 1 : 0.4) // a plain button does not dim itself when disabled
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: selected)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A picture to choose, outlined in the accent colour when chosen, as System Settings shows wallpapers.
private struct Choice<Content: View>: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.s) {
                content().frame(maxWidth: .infinity, minHeight: 30)
                Text(title).font(.caption).lineLimit(1)
            }
            .padding(.vertical, Space.m).padding(.horizontal, Space.s)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                if selected {
                    shape.fill(.tint.opacity(0.2))
                    shape.strokeBorder(.tint, lineWidth: 1.5)
                } else if hovering && isEnabled {
                    shape.fill(.quaternary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .opacity(isEnabled ? 1 : 0.4) // a plain button does not dim itself when disabled
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: selected)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private let threeColumns = Array(repeating: GridItem(.flexible(), spacing: Space.s), count: 3)

// MARK: - Tabs

private struct WeatherTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        let _ = bodyRan("weather")
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.l) {
                if Effect.shipping.count > 1 {
                    LazyVGrid(columns: threeColumns, spacing: Space.l) {
                        ForEach(Effect.shipping) { e in
                            RoundChoice(title: e.title, symbol: e.symbol, selected: state.effect == e) { state.effect = e }
                        }
                    }
                } else {
                    Label(state.effect.title, systemImage: state.effect.symbol).font(.headline)
                }
                Text(state.effect.blurb).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .module()
            VStack(alignment: .leading, spacing: Space.m) {
                sliderRow("Amount", $state.intensity, 0.2...2, low: "aqi.low", high: "aqi.high")
                sliderRow("Wind", $state.wind, -1...1, low: "arrow.left", high: "arrow.right")
                sliderRow("Opacity", $state.opacity, 0.25...1, low: "circle.dotted", high: "circle.fill")
            }
            .module()
            VStack(alignment: .leading, spacing: Space.m) {
                switchRow("Fall behind windows", $state.behindWindows)
                if state.effect == .snow { switchRow("Let settled snow melt", $state.melt) }
            }
            .module()
            if let note = state.powerNote {
                Label("\(note), so effects run lighter", systemImage: "leaf")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .animation(.snappy(duration: 0.22), value: state.powerNote)
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
        let _ = bodyRan("christmas")
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.m) {
                switchRow("Show decorations", $state.showDecor)
                HStack {
                    Button { engine.growTree() } label: {
                        Label("Grow a tree (\(state.decorSummary.trees) of 3)", systemImage: "tree.fill")
                            .contentTransition(.numericText(value: Double(state.decorSummary.trees)))   // the count rolls
                    }
                    .disabled(state.decorSummary.trees >= 3)
                    Button {
                        snowNote = engine.rollSnowman()
                        if snowNote != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 4) { snowNote = nil } }
                    } label: { Label("Roll a snowman", systemImage: "figure.wave") }
                        .disabled(state.decorSummary.snowmenFull)
                }
                .controlSize(.small)
                .disabled(!state.showDecor)
                if let note = snowNote {
                    Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .module()

            VStack(alignment: .leading, spacing: Space.l) {
                LazyVGrid(columns: threeColumns, spacing: Space.l) {
                    ForEach(Tool.allCases) { t in
                        RoundChoice(title: t.title, symbol: icon(t), selected: state.tool == t) { state.tool = t }
                    }
                }
                .disabled(!state.showDecor)
                Text(state.showDecor ? hint : "Turn on decorations to grow trees, roll snowmen and meet the visitors.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .module()
            .animation(.easeOut(duration: 0.18), value: state.tool)

            VStack(alignment: .leading, spacing: Space.m) {
                Text("Visitors").font(.headline)
                switchRow("Santa flies over and drops presents", $state.santaVisits)
                switchRow("The gift train delivers to your trees", $state.trainVisits)
                switchRow("A Yeti tries to steal your snowmen", $state.yetiVisits)
                HStack {
                    Button("Call Santa") { engine.mainScene?.callSanta() }
                    Button("Send the train") { engine.mainScene?.sendTrain() }
                        .disabled(state.decorSummary.trees == 0)
                        .help("The train delivers to a tree: grow one first.")
                    Button("Summon the Yeti") { engine.mainScene?.summonYeti() }
                }
                .controlSize(.small)
                .disabled(!state.showDecor)
            }
            .module()

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
            .disabled(state.decorSummary.isEmpty)
        }
        // Notes come and go, the clear button asks again, and switching decorations off greys the controls,
        // each eased rather than snapped.
        .animation(.snappy(duration: 0.22), value: snowNote)
        .animation(.snappy(duration: 0.2), value: clearArmed)
        .animation(.easeInOut(duration: 0.22), value: state.showDecor)
        .animation(.snappy(duration: 0.25), value: state.decorSummary.trees)
    }
}

private struct WallpaperTab: View {
    @ObservedObject var state: AppState
    @ObservedObject private var walls = WallpaperManager.shared
    @ObservedObject private var sun = Sun.shared

    var body: some View {
        let _ = bodyRan("wallpaper")
        VStack(alignment: .leading, spacing: Space.m) {
            LazyVGrid(columns: threeColumns, spacing: Space.s) {
                Choice(title: "Your own", selected: state.theme == nil, action: { state.theme = nil }) {
                    Image(systemName: "photo").font(.title2)
                }
                ForEach(Theme.shipping) { t in
                    Choice(title: t.title, selected: state.theme == t, action: { state.theme = t }) {
                        thumb(t)
                    }
                }
            }
            .module()
            VStack(alignment: .leading, spacing: Space.m) {
                switchRow("Follow the time of day", $state.dayNight)
                if state.dayNight {
                    Text("Showing the \(TimeOfDay.now().light.rawValue) painting now, and the weather is lit to match. "
                         + sun.today)
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Light", selection: Binding(get: { state.fixedTime.light },
                                                       set: { state.fixedTime = Self.representative[$0] ?? .midday })) {
                        ForEach(Light.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .module()
            if let note = state.wallpaperNote {
                Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .animation(.snappy(duration: 0.22), value: state.dayNight)
        .animation(.snappy(duration: 0.22), value: state.wallpaperNote)
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
    /// Registered, but macOS waits for the user to allow it in System Settings > Login Items.
    @State private var needsOK = false

    private func setAtLogin(_ on: Bool) {
        atLogin = on
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "macOS didn't allow it: \(error.localizedDescription)"
        }
        Task { await readLogin() }
    }

    /// Read again whenever the panel comes forward: the user may have changed it in System Settings.
    private func readLogin() async {
        let status = await Task.detached { SMAppService.mainApp.status }.value
        Self.knownAtLogin = status == .enabled
        atLogin = status == .enabled || status == .requiresApproval
        needsOK = status == .requiresApproval
    }

    static let reportURL: URL = {
        var c = URLComponents(string: "https://github.com/AmeenShareif/windowsill/issues/new")!
        c.queryItems = [URLQueryItem(name: "body", value: "\(version), macOS "
            + "\(ProcessInfo.processInfo.operatingSystemVersionString)\n\nWhat happened:\n")]
        return c.url!
    }()

    static let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String
        return "Version \(short)" + (build.map { " (\($0))" } ?? "")
    }()

    var body: some View {
        let _ = bodyRan("settings")
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.m) {
                switchRow("Open at login", Binding(get: { atLogin }, set: setAtLogin))
                    .task { await readLogin() }
                    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                        Task { await readLogin() }
                    }
                if let e = loginError { Text(e).font(.caption).foregroundStyle(.red) }
                if needsOK {
                    HStack {
                        Text("Allow Windowsill in Login Items to finish.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                            .controlSize(.small)
                    }
                }
                switchRow("Show on every display", $state.allScreens)
                switchRow("Keep going over full-screen apps", $state.overFullScreen)
                switchRow("Show in screenshots and screen sharing", $state.inScreenshots)
                switchRow("Check for new versions", $state.checkUpdates)
                    .onChange(of: state.checkUpdates) { Updates.shared.check() }
            }
            .module()
            VStack(alignment: .leading, spacing: Space.s) {
                LabeledContent("Power") {
                    Text(state.powerNote.map { "\($0): half density, 30 fps" } ?? "Full quality, 60 fps")
                }
                Text((state.overFullScreen ? "Effects pause" : "Effects pause under full-screen apps,")
                     + " while the display sleeps and while the screen is locked. Windowsill collects nothing. "
                     + (state.checkUpdates ? "Its only connection is a daily look at GitHub for a new version."
                                           : "It makes no network connections."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .module()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.version).foregroundStyle(.secondary)
                    Link("Report a problem", destination: Self.reportURL)
                }
                .font(.caption)
                Spacer()
                Button("Quit Windowsill") { NSApp.terminate(nil) }
            }
        }
        .animation(.snappy(duration: 0.22), value: loginError)
        .animation(.snappy(duration: 0.22), value: needsOK)
    }
}

// MARK: - Live header scene

private struct SkyPreview: View {
    let effect: Effect
    let running: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var onScreen = false

    var body: some View {
        let _ = bodyRan("sky")
        // The environment's value redraws this when the setting changes; ReduceMotion.on lets the demo build move.
        let still = !running || (reduceMotion && ReduceMotion.on)
        // A closed panel is still a window, and its TimelineView kept ticking: two closed panels took 4% of the
        // main thread on CI (2026-11-19). The sky moves only while its window is on screen.
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still || !onScreen)) { tl in
            Canvas { ctx, size in
                SkyPainter.paint(&ctx, size, effect, still ? 6 : tl.date.timeIntervalSinceReferenceDate)
            }
        }
        .background(OnScreen(visible: $onScreen))
        .accessibilityHidden(true)
    }
}

/// Whether the view's window is on screen, as AppKit's occlusion state says.
private struct OnScreen: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> Probe {
        let visible = $visible
        return Probe { on in if visible.wrappedValue != on { visible.wrappedValue = on } }
    }

    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        private let report: (Bool) -> Void
        private var watch: NSObjectProtocol?

        init(report: @escaping (Bool) -> Void) {
            self.report = report
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        deinit { if let watch { NotificationCenter.default.removeObserver(watch) } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let watch { NotificationCenter.default.removeObserver(watch) }
            watch = window.map { w in
                NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                       object: w, queue: .main) { [weak self] _ in self?.tell() }
            }
            tell()
        }

        private func tell() {
            let on = window?.occlusionState.contains(.visible) == true
            DispatchQueue.main.async { [report] in report(on) }   // never in the middle of a view update
        }
    }
}

/// Draws the header tile from the clock alone, so it needs no state and a still frame is free.
enum SkyPainter {
    /// A stable pseudo-random number in 0..<1 for particle `i`, channel `k`.
    static func rand(_ i: Int, _ k: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43758.5453
        return x - floor(x)
    }

    static func paint(_ ctx: inout GraphicsContext, _ size: CGSize, _ e: Effect, _ t: Double) {
        let look = Look.of(e), w = size.width, h = size.height
        // Counts and sizes were set for a 320-point-wide header; the tile is a few dozen points, so scale them
        // down, or 70 flakes in a 52-point square read as static.
        let sc = max(0.25, Double(w) / 320), z = max(0.6, sc)
        func n(_ count: Int) -> Int { max(3, Int(Double(count) * sc)) }
        let ledge = min(14, h * 0.16), floor = h - ledge
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
            for i in 0..<n(70) {
                let p = fall(i, speed: 14...34, sway: 6), r = 1 + rand(i, 5) * 1.6
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(.white.opacity(0.55 + rand(i, 6) * 0.4)))
            }
        case .leaves, .sakura:
            let colors: [Color] = e == .leaves
                ? [Color(hex: 0xE0892B), Color(hex: 0xB9471F), Color(hex: 0xE8B53A)]
                : [Color(hex: 0xF7B8CF), Color(hex: 0xFBD3E0), Color(hex: 0xEE9DBC)]
            for i in 0..<n(e == .leaves ? 14 : 24) {
                let p = fall(i, speed: e == .leaves ? 18...34 : 12...24, sway: (e == .leaves ? 14 : 9) * z)
                var leaf = ctx
                leaf.translateBy(x: p.x, y: p.y)
                leaf.rotate(by: .radians(t * (1 + rand(i, 7)) + rand(i, 8) * 6.3))
                let s = CGFloat(e == .leaves ? 4 : 2.8) * z
                leaf.fill(Path(ellipseIn: CGRect(x: -s * 1.6, y: -s, width: s * 3.2, height: s * 2)),
                          with: .color(colors[i % colors.count]))
            }
        case .rain:
            for i in 0..<n(90) {
                let p = fall(i, speed: (240 * z)...(320 * z), sway: 0)
                var line = Path()
                line.move(to: p)
                line.addLine(to: CGPoint(x: p.x - 2.5 * z, y: p.y + 9 * z))
                ctx.stroke(line, with: .color(.white.opacity(0.45)), lineWidth: 1)
            }
        case .starfall:
            for i in 0..<n(45) {
                let x = rand(i, 1) * Double(w), y = rand(i, 2) * Double(floor - 8 * z)
                let a = 0.35 + 0.35 * sin(t * (1 + rand(i, 3) * 2) + rand(i, 4) * 6.3)
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)), with: .color(.white.opacity(a)))
            }
            for i in 0..<(sc < 0.5 ? 1 : 3) {
                let phase = (t / 2.8 + rand(i + 50, 1)).truncatingRemainder(dividingBy: 1)
                guard phase < 0.3 else { continue }
                let k = phase / 0.3
                let x0 = Double(w) * (0.45 + rand(i + 50, 2) * 0.5), y0 = Double(floor) * rand(i + 50, 3) * 0.4
                let head = CGPoint(x: x0 - 110 * sc * k, y: y0 + 46 * sc * k)
                let end = CGPoint(x: head.x + 34 * z, y: head.y - 14 * z)
                var tail = Path()
                tail.move(to: end)
                tail.addLine(to: head)
                ctx.stroke(tail, with: .linearGradient(Gradient(colors: [.clear, Color(hex: 0xFFF2C4)]),
                                                       startPoint: end, endPoint: head),
                           lineWidth: 1.6)
            }
        case .fireflies:
            for i in 0..<n(12) {
                let x = Double(w) * (0.5 + 0.44 * sin(t * 0.3 * (0.5 + rand(i, 1)) + rand(i, 2) * 6.3))
                let y = Double(floor) * (0.5 + 0.36 * sin(t * 0.37 * (0.5 + rand(i, 3)) + rand(i, 4) * 6.3))
                let a = 0.5 + 0.5 * sin(t * 2 + rand(i, 5) * 6.3)
                let c = CGPoint(x: x, y: y)
                let r = 9 * z
                ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                         with: .radialGradient(Gradient(colors: [Color(hex: 0xE4F59A).opacity(a), .clear]),
                                               center: c, startRadius: 0, endRadius: r))
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
                drift.addLine(to: CGPoint(x: x, y: Double(floor) - (3.5 + 2 * sin(x * 0.045) + sin(x * 0.13)) * z))
            }
            drift.addLine(to: CGPoint(x: w, y: floor))
            drift.closeSubpath()
            ctx.fill(drift, with: .color(Color(hex: 0xF4F8FC)))
        case .leaves, .sakura:
            let colors: [Color] = e == .leaves ? [Color(hex: 0xC2581F), Color(hex: 0xE0892B)] : [Color(hex: 0xF7B8CF), Color(hex: 0xEE9DBC)]
            for i in 0..<n(e == .leaves ? 7 : 10) {
                let x = rand(i + 90, 1) * Double(w)
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: Double(floor) - 2.5 * z, width: (e == .leaves ? 10 : 7) * z,
                                                height: 3.5 * z)),
                         with: .color(colors[i % colors.count]))
            }
        default:
            break
        }
    }
}
