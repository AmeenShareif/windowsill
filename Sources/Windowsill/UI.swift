import SwiftUI
import ServiceManagement

struct PanelView: View {
    enum Tab: String, CaseIterable { case weather = "Weather", christmas = "Christmas", wallpapers = "Wallpapers", settings = "Settings" }

    @ObservedObject private var state = AppState.shared
    @State private var tab = Tab.weather

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: state.effect.symbol).foregroundStyle(.tint)
                Text("Windowsill").font(.headline)
                Spacer()
                Toggle("Effects on", isOn: $state.enabled).toggleStyle(.switch).labelsHidden()
            }
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            switch tab {
            case .weather: WeatherTab(state: state)
            case .christmas: ChristmasTab(state: state)
            case .wallpapers: WallpaperTab(state: state)
            case .settings: SettingsTab(state: state)
            }
        }
        .padding(14)
        .frame(width: 344)
    }
}

/// A square picker tile: symbol or picture on top, caption below.
private struct Tile<Content: View>: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                content().frame(maxWidth: .infinity, minHeight: 34)
                Text(title).font(.caption).lineLimit(1)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private let threeColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

private struct WeatherTab: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: threeColumns, spacing: 8) {
                ForEach(Effect.allCases) { e in
                    Tile(title: e.title, selected: state.effect == e, action: { state.effect = e }) {
                        Image(systemName: e.symbol).font(.title2)
                    }
                }
            }
            Text(state.effect.blurb).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Amount") { Slider(value: $state.intensity, in: 0.2...2) }
            LabeledContent("Wind") {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.left").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $state.wind, in: -1...1)
                    Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if state.onBattery {
                Label("Battery saver: lighter effects", systemImage: "battery.50").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ChristmasTab: View {
    @ObservedObject var state: AppState
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
        default: return "Click a tree to hang \(state.tool.title.lowercased())."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show decorations", isOn: $state.showDecor)
            HStack {
                Button { engine.growTree() } label: {
                    Label("Grow a tree (\(state.decor.trees.count)/3)", systemImage: "tree.fill")
                }
                .disabled(state.decor.trees.count >= 3)
                Button { engine.rollSnowman() } label: { Label("Roll a snowman", systemImage: "figure.wave") }
                    .disabled(state.decor.snowmen.count >= 6)
            }
            .disabled(!state.showDecor)

            LazyVGrid(columns: threeColumns, spacing: 8) {
                ForEach(Tool.allCases) { t in
                    Tile(title: t.title, selected: state.tool == t, action: { state.tool = t }) {
                        Image(systemName: icon(t)).font(.title3)
                    }
                }
            }
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            Text("Visitors").font(.subheadline.weight(.semibold))
            Toggle("Santa flies over and drops presents", isOn: $state.santaVisits)
            Toggle("The gift train delivers to your trees", isOn: $state.trainVisits)
            Toggle("A Yeti tries to steal your snowmen", isOn: $state.yetiVisits)
            HStack {
                Button("Call Santa") { engine.mainScene?.callSanta() }
                Button("Send the train") { engine.mainScene?.sendTrain() }
                Button("Summon the Yeti") { engine.mainScene?.summonYeti() }
            }
            .controlSize(.small)
            .disabled(!state.showDecor)
            Button("Clear all decorations", role: .destructive) { engine.clearDecor() }
                .controlSize(.small)
        }
    }
}

private struct WallpaperTab: View {
    @ObservedObject var state: AppState
    @ObservedObject private var walls = WallpaperManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: threeColumns, spacing: 8) {
                Tile(title: "None", selected: state.theme == nil, action: { state.theme = nil }) {
                    Image(systemName: "nosign").font(.title2).foregroundStyle(.secondary)
                }
                ForEach(Theme.allCases) { t in
                    Tile(title: t.title, selected: state.theme == t, action: { state.theme = t }) {
                        thumb(t)
                    }
                }
            }
            Toggle("Follow the time of day", isOn: $state.dayNight)
            if state.dayNight {
                Text("Now showing \(TimeOfDay.now().title.lowercased()). The picture changes through the day.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(TimeOfDay.allCases) { t in
                        Button(t.title) { state.fixedTime = t }
                            .buttonStyle(.bordered)
                            .tint(state.fixedTime == t ? .accentColor : nil)
                            .controlSize(.small)
                    }
                }
            }
            if let note = state.wallpaperNote {
                Label(note, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { walls.loadThumbs() }
        .onChange(of: state.fixedTime) { walls.loadThumbs() }
        .onChange(of: state.dayNight) { walls.loadThumbs() }
    }

    @ViewBuilder private func thumb(_ t: Theme) -> some View {
        if let img = walls.thumbs[t] {
            Image(nsImage: img).resizable().aspectRatio(16.0 / 10, contentMode: .fill)
                .frame(height: 50).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(height: 50)
        }
    }
}

private struct SettingsTab: View {
    @ObservedObject var state: AppState
    @State private var atLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Open at login", isOn: $atLogin)
                .onChange(of: atLogin) {
                    do {
                        if atLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        atLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let e = loginError { Text(e).font(.caption).foregroundStyle(.red) }
            Toggle("Show on every display", isOn: $state.allScreens)
            LabeledContent("Power") {
                Text(state.onBattery ? "Battery: half density, 30 fps" : "Plugged in: full quality")
            }
            Text("Effects pause by themselves under full-screen apps and while the display sleeps. Windowsill makes no network connections and collects nothing.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Quit Windowsill") { NSApp.terminate(nil) }
            }
        }
    }
}
