import Foundation
import CoreGraphics

enum Effect: String, CaseIterable, Identifiable {
    case snow, leaves, starfall, rain, sakura, fireflies
    var id: String { rawValue }

    /// What the panel offers. Only the winter/Christmas theme ships for now (2026-11-19); the rest is roadmap.
    static let shipping: [Effect] = [.snow]

    var title: String {
        switch self {
        case .snow: return "Snow"
        case .leaves: return "Leaves"
        case .starfall: return "Starfall"
        case .rain: return "Rain"
        case .sakura: return "Sakura"
        case .fireflies: return "Fireflies"
        }
    }

    var symbol: String {
        switch self {
        case .snow: return "snowflake"
        case .leaves: return "leaf.fill"
        case .starfall: return "sparkles"
        case .rain: return "cloud.rain.fill"
        case .sakura: return "camera.macro"
        case .fireflies: return "sparkle"
        }
    }

    var blurb: String {
        switch self {
        case .snow: return "Piles up on window tops and the Dock. Drag a window and it flies off."
        case .leaves: return "Autumn leaves pile up and scatter when you brush past them."
        case .starfall: return "Shooting stars streak across and burst into sparks on your windows."
        case .rain: return "Drops splash where they land, with lightning now and then."
        case .sakura: return "Cherry blossom drifts down and rests on your windows for a while."
        case .fireflies: return "Soft lights drift around and gather where your pointer rests."
        }
    }
}

enum Theme: String, CaseIterable, Identifiable {
    case winter, rain, stars, fireflies, autumn, spring
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// The paintings the panel offers and the app bundles (scripts/build-app.sh copies only these).
    static let shipping: [Theme] = [.winter]
}

enum TimeOfDay: String, CaseIterable, Identifiable {
    case dawn, sunrise, morning, midday, golden, sunset, dusk, night
    var id: String { rawValue }

    var title: String { self == .golden ? "Golden hour" : rawValue.capitalized }

    /// The real time of day here, from where the sun is (Sun.swift).
    static func now() -> TimeOfDay { Sun.shared.timeOfDay }
}

enum Tool: String, CaseIterable, Identifiable {
    case move, bauble, lights, cane, star, remove
    var id: String { rawValue }

    var title: String {
        switch self {
        case .move: return "Move"
        case .bauble: return "Bauble"
        case .lights: return "Lights"
        case .cane: return "Cane"
        case .star: return "Star"
        case .remove: return "Remove"
        }
    }

    var ornament: Ornament.Kind? {
        switch self {
        case .bauble: return .bauble
        case .lights: return .lights
        case .cane: return .cane
        case .star: return .star
        case .move, .remove: return nil
        }
    }
}

// MARK: - Decorations (positions are global Cocoa points: origin bottom-left of the main screen)

struct Ornament: Codable, Equatable {
    enum Kind: String, Codable { case bauble, lights, cane, star }
    var kind: Kind
    var x: CGFloat   // tree-local: origin at the trunk's base centre
    var y: CGFloat
    var color: Int
}

struct TreeItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var x: CGFloat
    var y: CGFloat
    var ornaments: [Ornament] = []
}

struct SnowmanItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var x: CGFloat
    var y: CGFloat
    var windowId: Int? = nil     // the window it sits on; window numbers do not survive a relaunch
    var offsetX: CGFloat = 0
}

struct PresentItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var x: CGFloat
    var y: CGFloat
    var anchored = false         // under a tree: no gravity
    var windowId: Int? = nil     // the window it landed on, if any; it rides along
    var offsetX: CGFloat? = nil  // optional so decorations saved before presents could ride still decode
}

struct Decor: Codable, Equatable {
    var trees: [TreeItem] = []
    var snowmen: [SnowmanItem] = []
    var presents: [PresentItem] = []
}

// MARK: - App state

final class AppState: ObservableObject {
    static let shared = AppState()
    private let store: UserDefaults

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "enabled") } }
    @Published var effect: Effect { didSet { store.set(effect.rawValue, forKey: "effect") } }
    @Published var intensity: Double { didSet { store.set(intensity, forKey: "intensity") } }
    @Published var wind: Double { didSet { store.set(wind, forKey: "wind") } }
    @Published var opacity: Double { didSet { store.set(opacity, forKey: "opacity") } }
    @Published var melt: Bool { didSet { store.set(melt, forKey: "melt") } }
    @Published var behindWindows: Bool { didSet { store.set(behindWindows, forKey: "behindWindows") } }
    @Published var overFullScreen: Bool { didSet { store.set(overFullScreen, forKey: "overFullScreen") } }
    /// Off by default: a screen share or a screenshot of your work should show your work.
    @Published var inScreenshots: Bool { didSet { store.set(inScreenshots, forKey: "inScreenshots") } }
    @Published var allScreens: Bool { didSet { store.set(allScreens, forKey: "allScreens") } }
    @Published var checkUpdates: Bool { didSet { store.set(checkUpdates, forKey: "checkUpdates") } }
    @Published var showDecor: Bool { didSet { store.set(showDecor, forKey: "showDecor") } }
    @Published var santaVisits: Bool { didSet { store.set(santaVisits, forKey: "santaVisits") } }
    @Published var trainVisits: Bool { didSet { store.set(trainVisits, forKey: "trainVisits") } }
    @Published var yetiVisits: Bool { didSet { store.set(yetiVisits, forKey: "yetiVisits") } }
    @Published var theme: Theme? { didSet { store.set(theme?.rawValue, forKey: "theme") } }
    @Published var fixedTime: TimeOfDay { didSet { store.set(fixedTime.rawValue, forKey: "fixedTime") } }
    @Published var dayNight: Bool { didSet { store.set(dayNight, forKey: "dayNight") } }
    @Published var decor: Decor {
        didSet { if let data = try? JSONEncoder().encode(decor) { store.set(data, forKey: "decor") } }
    }
    @Published var tool: Tool = .move
    /// Why effects run lighter right now (battery, Low Power Mode, heat), or nil at full quality.
    @Published var powerNote: String?
    @Published var wallpaperNote: String?

    /// Decorations made this session, so the scene animates them in instead of popping them.
    var freshIds = Set<UUID>()

    private init() {
        // The CI demo must never touch a real user's settings.
        let demo = CommandLine.arguments.contains("--demo")
        let suite = "app.windowsill.demo"
        if demo { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let s = demo ? (UserDefaults(suiteName: suite) ?? .standard) : .standard
        s.register(defaults: [
            "enabled": true, "effect": Effect.snow.rawValue, "intensity": 1.0, "wind": 0.15, "opacity": 1.0,
            "melt": false, "behindWindows": false, "overFullScreen": false, "inScreenshots": false, "allScreens": true, "checkUpdates": true, "showDecor": true, "santaVisits": true, "trainVisits": true,
            "yetiVisits": true, "fixedTime": TimeOfDay.night.rawValue, "dayNight": true,
        ])
        store = s
        enabled = s.bool(forKey: "enabled")
        // A choice saved by 1.0.0 that this build no longer offers falls back to the winter theme.
        effect = Effect(rawValue: s.string(forKey: "effect") ?? "").flatMap { Effect.shipping.contains($0) ? $0 : nil } ?? .snow
        intensity = s.double(forKey: "intensity")
        wind = s.double(forKey: "wind")
        opacity = s.double(forKey: "opacity")
        melt = s.bool(forKey: "melt")
        behindWindows = s.bool(forKey: "behindWindows")
        overFullScreen = s.bool(forKey: "overFullScreen")
        inScreenshots = s.bool(forKey: "inScreenshots")
        allScreens = s.bool(forKey: "allScreens")
        checkUpdates = s.bool(forKey: "checkUpdates")
        showDecor = s.bool(forKey: "showDecor")
        santaVisits = s.bool(forKey: "santaVisits")
        trainVisits = s.bool(forKey: "trainVisits")
        yetiVisits = s.bool(forKey: "yetiVisits")
        theme = s.string(forKey: "theme").flatMap { Theme(rawValue: $0) }.map { Theme.shipping.contains($0) ? $0 : .winter }
        fixedTime = TimeOfDay(rawValue: s.string(forKey: "fixedTime") ?? "") ?? .night
        dayNight = s.bool(forKey: "dayNight")
        var d = s.data(forKey: "decor").flatMap { try? JSONDecoder().decode(Decor.self, from: $0) } ?? Decor()
        for i in d.snowmen.indices { d.snowmen[i].windowId = nil }
        for i in d.presents.indices { d.presents[i].windowId = nil }
        decor = d
    }
}
