import AppKit
import Combine
import ImageIO

/// The three lights each painted scene ships in.
enum Light: String, CaseIterable { case day, evening, night }

extension TimeOfDay {
    var light: Light {
        switch self {
        case .morning, .midday, .golden: return .day
        case .dawn, .sunrise, .sunset, .dusk: return .evening
        case .night: return .night
        }
    }
}

/// Painted scenes live in Contents/Resources/Wallpapers as `<theme>-<light>.jpg`.
enum Wallpaper {
    static func url(_ theme: Theme, _ light: Light) -> URL? {
        Bundle.main.url(forResource: "\(theme.rawValue)-\(light.rawValue)", withExtension: "jpg", subdirectory: "Wallpapers")
    }

    /// A small decoded copy, so the panel never holds full-size paintings.
    static func thumbnail(_ url: URL, maxPixels: Int = 320) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Puts the chosen scene on every screen and keeps it in step with the clock.
final class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()
    @Published private(set) var thumbs: [Theme: NSImage] = [:]
    private var applied: String?
    private var thumbLight: Light?
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "windowsill.wallpaper", qos: .utility)
    /// How long each desktop change held the main thread, read and emptied by the demo's shot notes.
    var setCosts: [String] = []

    private var state: AppState { AppState.shared }
    var time: TimeOfDay { state.dayNight ? .now() : state.fixedTime }

    /// A copy outside the app, so the desktop keeps its picture if the app is moved or deleted.
    private var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Windowsill/wallpapers", isDirectory: true)
    }

    func start() {
        state.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.apply() } }.store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.apply() }.store(in: &bag)
        // Within a minute of the sun crossing into a new light; apply() does nothing while the light stays.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.apply() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        apply()
    }

    func apply() {
        guard let theme = state.theme else {
            if applied != nil { restoreOwn() }   // "Your own" picked after a painting: put theirs back
            applied = nil
            return
        }
        let light = time.light
        let key = "\(theme.rawValue)-\(light.rawValue)"
        // The screens are part of what was applied: a display plugged in kept its own picture until the
        // light next changed, hours away.
        let screens = NSScreen.screens
        let want = ([key] + screens.map(Self.id)).joined(separator: " ")
        guard want != applied else { return }
        applied = want
        guard let source = Wallpaper.url(theme, light) else {
            state.wallpaperNote = "The \(theme.title) painting is missing from this copy of the app."
            return
        }
        let folder = self.folder
        let target = folder.appendingPathComponent("\(key).jpg")
        saveOwn(screens)
        queue.async {
            var failure: String?
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if !FileManager.default.contentsEqual(atPath: source.path, andPath: target.path) {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.copyItem(at: source, to: target)
                }
            } catch {
                failure = "Couldn't copy the wallpaper: \(error.localizedDescription)"
            }
            let copyFailure = failure
            DispatchQueue.main.async {
                var note = copyFailure
                if note == nil {
                    let fill: [NSWorkspace.DesktopImageOptionKey: Any] = [
                        .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]
                    let t = CACurrentMediaTime()
                    for screen in screens {
                        do { try NSWorkspace.shared.setDesktopImageURL(target, for: screen, options: fill) }
                        catch { note = "macOS refused the wallpaper: \(error.localizedDescription)" }
                    }
                    // A frame gap as the light changes: is it this call, or the desktop redrawing after it?
                    let cost = "\(key) set in \(Int((CACurrentMediaTime() - t) * 1000)) ms"
                    self.setCosts = Array((self.setCosts + [cost]).suffix(8))
                }
                self.state.wallpaperNote = note
            }
        }
    }

    /// The user's own picture on each screen, saved before a painting first covers it (kept across launches),
    /// so choosing "Your own" again gives it back instead of leaving the painting up.
    private let ownKey = "ownWallpapers"
    private static func id(_ s: NSScreen) -> String {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? s.localizedName
    }

    private func saveOwn(_ screens: [NSScreen]) {
        var own = UserDefaults.standard.dictionary(forKey: ownKey) as? [String: String] ?? [:]
        for s in screens where own[Self.id(s)] == nil {
            guard let url = NSWorkspace.shared.desktopImageURL(for: s), !url.path.hasPrefix(folder.path) else { continue }
            own[Self.id(s)] = url.absoluteString
        }
        UserDefaults.standard.set(own, forKey: ownKey)
    }

    // ponytail: puts back the picture with Fill Screen (macOS's default), not the user's own scaling or colour,
    // and a moving aerial comes back as its still; save desktopImageOptions too if anyone misses theirs.
    private func restoreOwn() {
        let own = UserDefaults.standard.dictionary(forKey: ownKey) as? [String: String] ?? [:]
        let fill: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]
        for s in NSScreen.screens {
            guard let str = own[Self.id(s)], let url = URL(string: str) else {
                // Painted over by version 1.0.0, which kept nothing to put back.
                if NSWorkspace.shared.desktopImageURL(for: s)?.path.hasPrefix(folder.path) == true {
                    state.wallpaperNote = "Windowsill has no copy of the picture you had before. "
                        + "Choose it again in System Settings > Wallpaper."
                }
                continue
            }
            do { try NSWorkspace.shared.setDesktopImageURL(url, for: s, options: fill) }
            catch { state.wallpaperNote = "Couldn't put your own picture back: \(error.localizedDescription)" }
        }
        UserDefaults.standard.removeObject(forKey: ownKey)
    }

    func loadThumbs() {
        let light = time.light
        guard thumbLight != light else { return }
        thumbLight = light
        queue.async {
            var out: [Theme: NSImage] = [:]
            for theme in Theme.shipping {
                if let url = Wallpaper.url(theme, light), let img = Wallpaper.thumbnail(url) {
                    out[theme] = NSImage(cgImage: img, size: NSSize(width: 160, height: 100))
                }
            }
            let made = out
            DispatchQueue.main.async { self.thumbs = made }
        }
    }
}
