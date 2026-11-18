import AppKit
import ServiceManagement
import SwiftUI

@main
struct WindowsillApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Headless entry points, used by CI and by anyone checking a build.
        let args = CommandLine.arguments
        if args.contains("--selfcheck") { SelfCheck.run() }
    }

    var body: some Scene {
        MenuBarExtra("Windowsill", systemImage: "snowflake") {
            PanelView().background(AboveTheWeather())
        }
        .menuBarExtraStyle(.window)
    }
}

/// Run straight from the disk image (or from where macOS quarantines a downloaded app), Windowsill
/// stops when the image is ejected and cannot open at login. So offer to put it in Applications.
enum Install {
    static func needsMove(_ path: String) -> Bool {
        path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/")
    }

    /// Returns true when the app is being moved and relaunched, so nothing else should start.
    static func offerMove() -> Bool {
        let here = Bundle.main.bundleURL
        guard needsMove(here.path) else { return false }
        let alert = NSAlert()
        alert.messageText = "Move Windowsill to Applications?"
        alert.informativeText = "It's running from the disk image, so it will stop when the image is ejected and can't open at login."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        do {
            let dest = try copy(here)
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: dest, configuration: config) { _, error in
                DispatchQueue.main.async {
                    if let error { NSAlert(error: error).runModal() } else { NSApp.terminate(nil) }
                }
            }
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    private static func copy(_ app: URL) throws -> URL {
        let fm = FileManager.default
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let folder = fm.isWritableFile(atPath: system.path) ? system
            : fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(app.lastPathComponent)
        if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
        try fm.copyItem(at: app, to: dest)
        // The copy keeps the download's quarantine flag, and macOS would run it from a random read-only
        // folder again. This copy already passed Gatekeeper to get this far, so the flag can go.
        let inside = (fm.subpaths(atPath: dest.path) ?? []).map { dest.path + "/" + $0 }
        for path in [dest.path] + inside { removexattr(path, "com.apple.quarantine", XATTR_NOFOLLOW) }
        return dest
    }
}

/// The weather overlay sits at status-window level; the panel goes one above it, so no flake ever
/// lands on a control. Menus the panel opens are higher still.
struct AboveTheWeather: NSViewRepresentable {
    static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    final class Probe: NSView {
        override func viewDidMoveToWindow() { window?.level = AboveTheWeather.level }
    }
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) { nsView.window?.level = Self.level }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var demo: DemoRun?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        Engine.shared.start()
        if let d = Demo.parse(CommandLine.arguments) {
            demo = DemoRun(d)
            demo?.start()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if !Install.offerMove() { Self.welcomeOnce() }
            }
        }
    }

    /// A menu bar app shows nothing on its first launch, so say where it lives, once.
    private static func welcomeOnce() {
        let key = "welcomed"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let alert = NSAlert()
        alert.messageText = "Windowsill is in your menu bar"
        alert.informativeText = "Click the snowflake at the top of the screen to choose the weather, decorate for "
            + "Christmas or change the wallpaper. Snow settles on your windows and the Dock; drag a window to carry it."
        alert.addButton(withTitle: "Got it")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Open Windowsill at login"
        NSApp.activate()
        alert.runModal()
        if alert.suppressionButton?.state == .on { try? SMAppService.mainApp.register() }
    }
}
