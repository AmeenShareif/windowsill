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

    // The snowflake and its panel are AppKit's (MenuPanel). SwiftUI wants a scene: this one is what Command-comma
    // opens, the same panel in a window, above the weather like the others.
    var body: some Scene {
        Settings { PanelView().background(AboveTheWeather()) }
    }
}

/// The snowflake in the menu bar and the panel it opens. SwiftUI's MenuBarExtra built and drew its panel on the
/// first click, which held up the falling weather (0.3 to 0.8 s on a CI Mac with no GPU), and on macOS 27 it
/// opened only for a click from the mouse itself, not for a press from VoiceOver. This one is built and drawn at
/// launch, and the snowflake is an ordinary button.
final class MenuPanel: NSObject, NSWindowDelegate {
    static let shared = MenuPanel()
    private var item: NSStatusItem?
    private var outside: Any?
    private var top: CGFloat?
    /// The size fit() last asked for; mid-animation the frame is somewhere on the way to it.
    private var fitted: CGSize?
    /// Fading out after a close: still on screen, no longer open.
    private(set) var closing = false
    private(set) lazy var panel: NSPanel = makePanel()

    /// Open and staying open.
    var isOpen: Bool { panel.isVisible && !closing }
    private var motion: Bool { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A borderless panel that still takes the keyboard, and closes on Escape as a menu does.
    private final class Floating: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { MenuPanel.shared.close() }
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "Windowsill"
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "snowflake", accessibilityDescription: "Windowsill")
            b.target = self
            b.action = #selector(toggle)
        }
        self.item = item
    }

    @objc func toggle() { isOpen ? close() : open() }

    func open() {
        guard let b = item?.button, let bw = b.window else { return }
        // Under the snowflake, its right edge on the snowflake's as the menu bar placed its own, kept on screen.
        var r = bw.convertToScreen(b.convert(b.bounds, to: nil))
        let screen = bw.screen ?? NSScreen.main
        let s = screen?.visibleFrame ?? r
        // A snowflake the menu bar has not placed yet reads as a zero rect at the screen's foot, and the
        // panel opened below the screen (macOS 27 CI, 2026-11-19): then under the right end of the menu bar.
        if r.height < 1 || r.maxY < (screen?.frame.maxY ?? r.maxY) - 1 {
            r = CGRect(x: s.maxX - 8, y: s.maxY, width: 0, height: 0)
        }
        let top = min(r.minY, s.maxY) - 2
        self.top = top
        closing = false   // opened again while fading out: it comes back from where the fade had got to
        if !panel.isVisible {
            panel.setFrameTopLeftPoint(CGPoint(x: max(s.minX + 8, min(r.maxX, s.maxX - 8) - panel.frame.width), y: top))
            panel.alphaValue = motion ? 0 : 1
        }
        fit()
        panel.makeKeyAndOrderFront(nil)   // the keyboard, without bringing the app forward (non-activating)
        if motion { fade(to: 1, over: 0.12) }   // in quickly, as Control Center's panels arrive
        // After the click: the button's own tracking clears its highlight once this action returns (CI, 2026-11-19).
        DispatchQueue.main.async { [weak self] in if self?.panel.isVisible == true { b.highlight(true) } }
        // A click in another app or the menu bar closes it, as it closes a menu.
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func close() {
        if let m = outside { NSEvent.removeMonitor(m); outside = nil }
        item?.button?.highlight(false)
        guard isOpen else { return }
        top = nil
        guard motion else { panel.orderOut(nil); return }
        closing = true
        fade(to: 0, over: 0.15) { [weak self] in   // out, as a menu fades
            guard let self, self.closing else { return }   // unless it was opened again meanwhile
            self.panel.orderOut(nil)   // still closing as it resigns key, so that close() leaves it be
            self.closing = false
            self.panel.alphaValue = 1
        }
    }

    private func fade(to alpha: CGFloat, over seconds: TimeInterval, then done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = seconds
            panel.animator().alphaValue = alpha
        }, completionHandler: done)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    /// A borderless window's shadow follows its old outline unless told, so it is redrawn at every step of a resize.
    /// Not through `panel`: makePanel() sizes the window before `panel` is set, and asking for it here then built
    /// another panel, which sized itself, and so on: the launch never finished (CI run 56, 2026-11-19).
    func windowDidResize(_ notification: Notification) { (notification.object as? NSWindow)?.invalidateShadow() }

    /// Keeps the panel the size of what it shows. A new tab changes its height, and it grows down from under
    /// the menu bar, not up into it: eased over a fifth of a second while the tabs cross-fade, at once when the
    /// panel is hidden or the Mac asks for less motion.
    func fit() {
        guard let host else { return }
        let size = host.fittingSize
        guard size.width > 0, size != fitted else { return }
        fitted = size
        let f = panel.frame
        let to = CGRect(x: f.minX, y: (top ?? f.maxY) - size.height, width: size.width, height: size.height)
        guard isOpen, motion else {
            panel.setFrame(to, display: true)
            panel.invalidateShadow()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.9, 0.3, 1)   // quick, then settles
            panel.animator().setFrame(to, display: true)
        }, completionHandler: { [weak self] in self?.panel.invalidateShadow() })
    }

    /// The panel's SwiftUI, which says when what it shows changes size.
    private final class Host: NSHostingView<PanelView> {
        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { MenuPanel.shared.fit() }   // once this layout pass is done
        }
    }
    private var host: Host?

    private func makePanel() -> NSPanel {
        let p = Floating(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
        p.title = "Windowsill"   // named for VoiceOver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = AboveTheWeather.level
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.delegate = self
        let host = Host(rootView: PanelView(anchorTop: true))
        host.sizingOptions = [.intrinsicContentSize]   // sized by fit(), so no min or max to fight the glass's own
        // Under the window's wish to keep its size (500), so a new tab's height does not resize the window at once
        // through Auto Layout, a snap in one frame (run 58), and fit() eases it there instead; still over the
        // fitting-size squeeze (50), so fittingSize stays the content's height.
        host.setContentHuggingPriority(.defaultLow, for: .vertical)
        host.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        host.autoresizingMask = [.width, .height]        // fills the glass, whichever way the glass lays it out
        let glass = NSGlassEffectView()
        glass.cornerRadius = 13   // the menu bar's own panel, measured on CI
        glass.contentView = host
        p.contentView = glass
        p.setContentSize(host.fittingSize)
        self.host = host
        return p
    }

    /// Shows windows once where nobody sees them, so their first real showing has nothing left to draw, then
    /// runs `done`.
    static func predraw(_ windows: [NSWindow], then done: @escaping () -> Void) {
        for w in windows {
            // Not 0: a window at 0 counts as hidden and nothing in it is drawn, so the first open still drew it all
            // (752 ms on a CI Mac, 2026-11-19). At 1% for a tenth of a second it is drawn and not seen.
            w.alphaValue = 0.01
            w.orderFrontRegardless()
            w.displayIfNeeded()
            if let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)   // every layer drawn once, now
            }
        }
        CATransaction.flush()
        // Past a full pass of the run loop, the one in which SwiftUI draws what it has laid out.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            for w in windows {
                w.orderOut(nil)
                w.alphaValue = 1
            }
            done()
        }
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
    #if DEMO
    private var demo: DemoRun?
    #endif
    private var reopened: NSPanel?

    /// The menu bar can hide the snowflake (behind the notch, or when the bar is full), and Apple asks a menu
    /// bar app not to depend on its icon being seen. So opening Windowsill again, from Finder, Spotlight or
    /// Launchpad, shows the same panel in a small window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let panel = reopened ?? Self.makePanel()
        reopened = panel
        if !panel.isVisible { panel.center() }   // on whichever screen is main now
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        return false
    }

    /// The panel a reopen shows, built and drawn at launch before the weather starts: built on the reopen, it
    /// held up the falling weather for 0.3 s on a CI Mac with no GPU.
    private static func makePanel() -> NSPanel {
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
        return p
    }

    /// How long building and drawing the panels took at launch, for the CI panel demo's notes.
    static var launchNote = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        let t = CACurrentMediaTime()
        MenuPanel.shared.install()
        let reopen = Self.makePanel()
        reopened = reopen
        MenuPanel.predraw([MenuPanel.shared.panel, reopen]) { [self] in
            Self.launchNote = String(format: "panels built and drawn at launch in %.0f ms, 100 ms of it a wait",
                                     (CACurrentMediaTime() - t) * 1000)
            Engine.shared.start()
            begin()
        }
    }

    /// Once the panels are drawn: the scripted demo in a CI demo build, otherwise the app's own first steps.
    @MainActor private func begin() {
        #if DEMO
        if let d = Demo.parse(CommandLine.arguments) {
            demo = DemoRun(d)
            demo?.start()
            return   // CI recordings make no network requests and ask nothing
        }
        #endif
        Updates.shared.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard !Install.offerMove() else { return }
            Self.welcomeOnce()
            Sun.shared.locate()   // after the welcome, which says why macOS is about to ask
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
            + "The light follows the sun where you are, so macOS will ask once whether Windowsill may use your rough "
            + "location. It stays on this Mac; without it, your time zone stands in.\n\n"
            + "If your menu bar is full and the snowflake is hidden, open Windowsill again from Applications."
        alert.addButton(withTitle: "Got it")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Open Windowsill at login"
        NSApp.activate()
        alert.runModal()
        if alert.suppressionButton?.state == .on { try? SMAppService.mainApp.register() }
    }
}
