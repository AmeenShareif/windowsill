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
    private var reopened: NSPanel?

    /// The menu bar can hide the snowflake (behind the notch, or when the bar is full), and Apple asks a menu
    /// bar app not to depend on its icon being seen. So opening Windowsill again, from Finder, Spotlight or
    /// Launchpad, shows the same panel in a small window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let panel = reopened ?? {
            // Non-activating, as the menu bar's own panel is: it takes the keyboard and draws its controls
            // active even when macOS declines to bring the app forward (grey on CI, 2026-11-18).
            let p = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.title = "Windowsill"            // still named for VoiceOver and the Window menu
            p.titleVisibility = .hidden       // the panel's own header says it once already
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false   // opened on purpose, so it stays until closed
            let host = NSHostingController(rootView: PanelView().background(AboveTheWeather()))
            p.contentViewController = host
            p.setContentSize(host.view.fittingSize)   // sized first: centred at zero size, it grew off to one side
            p.center()
            return p
        }()
        reopened = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        // Build and draw the panel once, off screen, before the weather starts: built cold on the first
        // click of the menu bar icon, it held up the falling weather (0.4 s on a CI Mac with no GPU).
        let warm = NSHostingView(rootView: PanelView())
        warm.frame.size = warm.fittingSize
        if let rep = warm.bitmapImageRepForCachingDisplay(in: warm.bounds) { warm.cacheDisplay(in: warm.bounds, to: rep) }
        Engine.shared.start()
        if let d = Demo.parse(CommandLine.arguments) {
            demo = DemoRun(d)
            demo?.start()
        } else {
            Updates.shared.start()   // never in a demo: CI recordings make no network requests
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
            + "Christmas or change the wallpaper. Snow settles on your windows and the Dock; drag a window to carry it.\n\n"
            + "If your menu bar is full and the snowflake is hidden, open Windowsill again from Applications."
        alert.addButton(withTitle: "Got it")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Open Windowsill at login"
        NSApp.activate()
        alert.runModal()
        if alert.suppressionButton?.state == .on { try? SMAppService.mainApp.register() }
    }
}
