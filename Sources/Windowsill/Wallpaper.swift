import AppKit
import Combine
import ImageIO

/// The three lights each painted scene ships in.
enum Light: String, CaseIterable { case day, evening, night }

extension TimeOfDay {
    var light: Light {
        switch self {
        case .morning, .midday, .golden: return .day
        case .sunrise, .sunset, .dusk: return .evening
        case .dawn, .night: return .night
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

    private var state: AppState { AppState.shared }
    var time: TimeOfDay { state.dayNight ? .now() : state.fixedTime }

    /// A copy outside the app, so the desktop keeps its picture if the app is moved or deleted.
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
        let light = time.light
        let key = "\(theme.rawValue)-\(light.rawValue)"
        guard key != applied else { return }
        applied = key
        guard let source = Wallpaper.url(theme, light) else {
            state.wallpaperNote = "The \(theme.title) painting is missing from this copy of the app."
            return
        }
        let folder = self.folder
        let target = folder.appendingPathComponent("\(key).jpg")
        let screens = NSScreen.screens
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
                    for screen in screens {
                        do { try NSWorkspace.shared.setDesktopImageURL(target, for: screen, options: fill) }
                        catch { note = "macOS refused the wallpaper: \(error.localizedDescription)" }
                    }
                }
                self.state.wallpaperNote = note
            }
        }
    }

    func loadThumbs() {
        let light = time.light
        guard thumbLight != light else { return }
        thumbLight = light
        queue.async {
            var out: [Theme: NSImage] = [:]
            for theme in Theme.allCases {
                if let url = Wallpaper.url(theme, light), let img = Wallpaper.thumbnail(url) {
                    out[theme] = NSImage(cgImage: img, size: NSSize(width: 160, height: 100))
                }
            }
            let made = out
            DispatchQueue.main.async { self.thumbs = made }
        }
    }
}
