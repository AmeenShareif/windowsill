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

/// Reduce Motion, as the app honours it. GitHub's Macs have it on, so the CI demo build, whose videos are there
/// to show the motion an ordinary Mac sees, reads it as off (run 62: every panel resize took the at-once path).
enum ReduceMotion {
    static var on: Bool {
        #if DEMO
        if isDemoRun { return false }
        #endif
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// The snowflake in the menu bar and the panel it opens. SwiftUI's MenuBarExtra built and drew its panel on the
/// first click, which held up the falling weather (0.3 to 0.8 s on a CI Mac with no GPU), and on macOS 27 it
/// opened only for a click from the mouse itself, not for a press from VoiceOver. This one is built and drawn at
/// launch, and the snowflake is an ordinary button.
final class MenuPanel: NSObject, NSWindowDelegate {
    static let shared = MenuPanel()
    /// The tab shown, as the tab picker shows it.
    private(set) var tab = PanelView.Tab.weather
    private(set) var item: NSStatusItem?
    private var outside: Any?
    private var top: CGFloat?
    /// The size fit() last asked for; mid-animation the frame is somewhere on the way to it.
    private var fitted: CGSize?
    /// Fading out after a close: still on screen, no longer open.
    private(set) var closing = false
    private(set) lazy var panel: NSPanel = makePanel()

    /// Open and staying open.
    var isOpen: Bool { panel.isVisible && !closing }
    private var motion: Bool { !ReduceMotion.on }

    /// A borderless panel that still takes the keyboard, and closes on Escape as a menu does.
    private final class Floating: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { MenuPanel.shared.close() }
    }

    /// Holds the keyboard while the panel is key and nothing in it has been chosen: Escape goes up from it to the
    /// panel's cancelOperation, Tab on to the controls (its nextKeyView). With no first responder of its own, the
    /// panel had AppKit look through SwiftUI's views for one each time it was made key, which laid out and drew
    /// every tab: 97 ms of a 115 ms open on CI (-[NSWindow _setUpFirstResponderBeforeBecomingVisible], run
    /// 45248910475), and why an open not made key cost 5-8 ms there.
    final class KeyHolder: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    /// The panel's content, flipped so that its pieces hang from the top edge however tall the window is.
    private final class Page: NSView {
        override var isFlipped: Bool { true }

        /// The window giving up the keyboard is not passed on to the pieces: it comes as the panel shuts, unseen,
        /// and each piece updated in full for it, about 100 ms of a shut on CI (run 45268190234, through
        /// NSHostingView._windowChangedKeyState). Becoming key still is, so the controls draw active once seen.
        /// Added at run time, and only while AppKit's method is the one measured; otherwise nothing changes.
        static let quietsKeyLoss: Bool = {
            let sel = NSSelectorFromString("_windowChangedKeyState")
            guard let m = class_getInstanceMethod(NSView.self, sel), let enc = method_getTypeEncoding(m),
                  String(cString: enc) == "v16@0:8" else { return false }
            typealias Call = @convention(c) (NSView, Selector) -> Void
            let inherited = unsafeBitCast(method_getImplementation(m), to: Call.self)
            let mine: @convention(block) (NSView) -> Void = { v in
                if v.window?.isKeyWindow != false { inherited(v, sel) }
            }
            return class_addMethod(Page.self, sel, imp_implementationWithBlock(mine), enc)
        }()

        /// SwiftUI's global environment changing reaches a piece only while it shows in the key panel: the panel
        /// taking and giving up the keyboard sends one change (-[NSWindow becomeKeyWindow], resignKeyWindow, to
        /// NSHostingView.globalEnvironmentDidChange), and every piece, hidden tabs too, updated in full for it,
        /// 9 to 102 ms each on CI (run 45282729109). A piece that missed any other change is told as it shows
        /// (catchUp). Added at run time to the hosting view's class, and only while SwiftUI's method is the one
        /// measured; otherwise nothing changes.
        static func quietsHidden(_ host: NSView) -> Bool {
            let sel = NSSelectorFromString("globalEnvironmentDidChange")
            guard let cls = object_getClass(host), !quieted.contains(ObjectIdentifier(cls)),
                  let m = class_getInstanceMethod(cls, sel), let enc = method_getTypeEncoding(m),
                  String(cString: enc) == "v16@0:8" else { return false }
            typealias Call = @convention(c) (NSView, Selector) -> Void
            let inherited = unsafeBitCast(method_getImplementation(m), to: Call.self)
            let mine: @convention(block) (NSView) -> Void = { v in
                let id = ObjectIdentifier(v), key = v.window?.isKeyWindow ?? true
                defer { keyed[id] = key }
                if !v.isHidden && key { behind.remove(id); return inherited(v, sel) }
                if keyed[id] == key { behind.insert(id) }   // the keyboard did not move: a change of its own
                #if DEMO
                SnowflakeLog.shared.note("piece \(Int(v.frame.height)) kept from a change\(behind.contains(id) ? ", behind" : "")")
                #endif
            }
            guard class_addMethod(cls, sel, imp_implementationWithBlock(mine), enc) else { return false }
            quieted.insert(ObjectIdentifier(cls))
            tell = { inherited($0, sel) }
            return true
        }
        private static var quieted = Set<ObjectIdentifier>()
        /// Whether the panel was key at the last change each piece heard of, and which pieces missed a change.
        private static var keyed: [ObjectIdentifier: Bool] = [:]
        private static var behind = Set<ObjectIdentifier>()
        private static var tell: (NSView) -> Void = { _ in }

        /// Tells a piece now showing of the change it missed while hidden, if it missed one.
        static func catchUp(_ v: NSView) {
            guard behind.remove(ObjectIdentifier(v)) != nil else { return }
            tell(v)
            #if DEMO
            MenuPanel.shared.trace.append("caught up \(Int(v.frame.height))")
            #endif
        }
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
        lookWatch = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.warmIfCold() }
        }
        // macOS 27 keeps a status button highlighted without drawing it (FB23330269), but draws the snowflake's
        // capsule for an expanded interface session, which a click then begins instead of sending the action
        // (CI, 2026-11-20). Set at run time: the macOS 26 SDK this builds with does not declare it.
        let setter = NSSelectorFromString("setExpandedInterfaceDelegate:")
        if item.responds(to: setter), let api = objc_getProtocol("NSStatusItemExpandedInterfaceDelegate") {
            class_addProtocol(MenuPanel.self, api)
            _ = item.perform(setter, with: self)
        }
    }

    /// macOS 27's session for the snowflake while the panel is open from it: the capsule shows until it ends.
    private var session: NSObject?
    /// When a click on the snowflake itself last closed the panel, so that click does not open it again.
    private var shutBySnowflake: CFTimeInterval = 0
    private var clickJustShutIt: Bool {
        defer { shutBySnowflake = 0 }
        return CACurrentMediaTime() - shutBySnowflake < 0.5
    }

    @objc func toggle() {
        log("button action")
        guard !clickJustShutIt else { return }
        isOpen ? close() : open()
    }

    @objc(statusItem:didBeginExpandedInterfaceSession:)
    func sessionBegan(_ item: NSStatusItem, session: NSObject) {
        log("session began")
        self.session = session
        if clickJustShutIt { return endSession() }
        open()
    }

    @objc(statusItemDidEndExpandedInterfaceSession:animated:)
    func sessionEnded(_ item: NSStatusItem, animated: Bool) {
        log("session ended")
        session = nil
        close()
    }

    private func endSession() {
        guard let s = session else { return }
        session = nil
        _ = s.perform(NSSelectorFromString("cancel"))
    }

    private var onSnowflake: Bool {
        guard let b = item?.button, let w = b.window else { return false }
        return w.convertToScreen(b.convert(b.bounds, to: nil)).contains(NSEvent.mouseLocation)
    }

    /// What the snowflake did, for the CI demo's notes; nothing in a release build.
    private func log(_ s: String) {
        #if DEMO
        SnowflakeLog.shared.note(s)
        #endif
    }

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
        // Never the window itself as first responder: then AppKit searches every tab for one (KeyHolder).
        if panel.firstResponder === panel, let h = panel.initialFirstResponder { panel.makeFirstResponder(h) }
        panel.makeKeyAndOrderFront(nil)   // the keyboard, without bringing the app forward (non-activating)
        if motion { fade(to: 1, over: 0.12) }   // in quickly, as Control Center's panels arrive
        warmIfCold()   // the look changed while it was shut
        // After the click: the button's own tracking clears its highlight once this action returns (CI, 2026-11-19).
        // Asked again a moment later in case tracking ends late. macOS 27 draws it only for a session (install()).
        for delay in [0, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in if self?.isOpen == true { b.highlight(true) } }
        }
        // A click in another app or the menu bar closes it, as it closes a menu. On macOS 27 a click on the
        // snowflake lands here too, before its own action or session, which then opened the panel again (CI,
        // 2026-11-20): that click is remembered, so it only closes.
        if let m = outside { NSEvent.removeMonitor(m) }
        outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            if self.onSnowflake {
                self.shutBySnowflake = CACurrentMediaTime()
                self.log("closed by a click on the snowflake")
            }
            self.close()
        }
    }

    func close() {
        if let m = outside { NSEvent.removeMonitor(m); outside = nil }
        item?.button?.highlight(false)
        endSession()
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

    /// The look (light or dark) every tab was last drawn in.
    private var warmLook: NSAppearance.Name?
    private var lookWatch: NSKeyValueObservation?
    private var warmings = 0

    private static var look: NSAppearance.Name? { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) }

    /// Draws each hidden tab once in a new look, unseen, while the panel is on screen; shut, it waits for open().
    /// Shown for the first time in a look, a tab drew everything as it was clicked (90 to 180 ms on CI, run
    /// 45217528066). One at a time, at 1% for a tenth of a second each: all at once, they held the look change up
    /// 266 to 447 ms (run 45260803079).
    private func warmIfCold() {
        let look = Self.look
        guard look != warmLook, panel.isVisible else { return }
        warmLook = look
        warmings += 1
        let n = warmings
        for (k, i) in pieces.indices.dropFirst().filter({ $0 != shownPiece }).enumerated() {
            let p = pieces[i]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 * Double(k + 1)) { [weak self] in
                guard let self, self.warmings == n, p.isHidden else { return }
                p.appearance = nil   // let go of the old look (rest())
                p.alphaValue = 0.01   // clicks pass it by (PieceHost)
                p.isHidden = false
                Page.catchUp(p)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    p.alphaValue = 1
                    if i != self.shownPiece { self.rest(p) }
                }
            }
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

    /// The panel's pieces, each a hosting view of its own: the top (header and tab picker), then each tab, all but
    /// the shown one hidden by AppKit. In one hosting view, a tab click updated every tab, 25 to 40 ms on CI (run
    /// 45257163291); hidden by AppKit, a tab sits out and a click costs 2 to 5 ms (run 45260803079).
    private var pieces: [NSView] = []
    /// Each piece's height, as it last measured itself (panelPiece).
    private var heights: [CGFloat] = []
    private var shownPiece: Int { (PanelView.Tab.allCases.firstIndex(of: tab) ?? 0) + 1 }

    /// Shows tab `t`, as a click on the tab picker asks.
    func show(_ t: PanelView.Tab) {
        #if DEMO
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        defer { trace.append("shown in \((clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1_000_000)ms") }
        #endif
        tab = t
        for (i, p) in pieces.enumerated().dropFirst() {
            p.alphaValue = 1
            guard i == shownPiece else { rest(p); continue }
            if p.appearance != nil { p.appearance = nil }   // kept in an old look: drawn in this one now
            p.isHidden = false
            Page.catchUp(p)
        }
        place()
    }

    /// Hides a piece and keeps it in the look it was last drawn in. Hidden by AppKit, a tab sits out of drawing but
    /// not out of a light/dark change: each was laid out anew in the change's frame, 13 to 15 ms apiece on macOS 27
    /// (run 45273851193). warmIfCold() brings them to the new look afterwards, one at a time.
    private func rest(_ p: NSView) {
        p.isHidden = true
        if p.appearance == nil { p.appearance = p.effectiveAppearance }
    }

    fileprivate func measured(_ piece: Int, _ height: CGFloat) {
        guard heights.indices.contains(piece), heights[piece] != height else { return }
        heights[piece] = height
        place()
    }

    /// Each piece at its own height under the top. The page is flipped, so a resize of the window moves and resizes
    /// none of them: resized with the window, the content was laid out and drawn anew at every step, each a new
    /// layer size (CI profile, run 45226029990).
    private func frames() {
        let w = pieces.first?.superview?.bounds.width ?? PanelView.width
        for (i, p) in pieces.enumerated() {
            let f = CGRect(x: 0, y: i == 0 ? 0 : heights[0], width: w, height: heights[i])
            if p.frame != f { p.frame = f }
        }
    }

    private func place() {
        frames()
        wanted = CGSize(width: PanelView.width, height: heights[0] + heights[shownPiece])
        fit()
    }

    /// What the panel shows: the top and the shown tab.
    private var wanted: CGSize?

    /// Keeps the panel the size of what it shows. A new tab changes its height, and it grows down from under
    /// the menu bar, not up into it: eased over a fifth of a second, at once when the panel is hidden, still
    /// fading in, or the Mac asks for less motion.
    private func fit() {
        guard let size = wanted, size.width > 0, size != fitted else { return }
        fitted = size
        let f = panel.frame
        let to = CGRect(x: f.minX, y: (top ?? f.maxY) - size.height, width: size.width, height: size.height)
        #if DEMO
        trace.append("[\(Int(f.height)) to \(Int(size.height)), open \(isOpen) motion \(motion) alpha \(panel.alphaValue)]")
        #endif
        guard isOpen, motion, panel.alphaValue > 0.5 else {
            resize = nil
            panel.setFrame(to, display: true)
            return
        }
        resize = (f, to, CACurrentMediaTime())
        if link == nil {
            let l = panel.displayLink(target: self, selector: #selector(step))
            l.add(to: .main, forMode: .common)
            link = l
        }
    }

    /// The resize under way: from, to, and when it began.
    private var resize: (from: CGRect, to: CGRect, start: CFTimeInterval)?
    private var link: CADisplayLink?
    private static let resizeTime: CFTimeInterval = 0.22

    /// One step of the resize per frame the display shows. The window's animator does not ease this one: a window
    /// whose views draw into layers jumps straight to the new frame (runs 58 and 59, one frame each way).
    @objc private func step(_ l: CADisplayLink) {
        guard let r = resize else {
            l.invalidate()
            link = nil
            return
        }
        let k = min(1, (CACurrentMediaTime() - r.start) / Self.resizeTime)
        let e = 1 - pow(1 - k, 3)   // eased out: quick, then settles
        let h = (r.from.height + (r.to.height - r.from.height) * e).rounded()
        #if DEMO
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        #endif
        panel.setFrame(CGRect(x: r.to.minX, y: r.to.maxY - h, width: r.to.width, height: h), display: true)
        #if DEMO
        trace.append("\(Int(h))->\(Int(panel.frame.height)) \((clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1_000_000)ms")
        #endif
        if k >= 1 { resize = nil }
    }

    #if DEMO
    /// What fit() and each step did, for the panel demo's notes.
    var trace: [String] = []
    #endif

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
        // The glass fills the window and `page` the glass, its pieces hanging from its top edge (frames()), so a
        // resize under way cuts the shown tab off at the bottom instead of resizing it.
        #if DEMO
        print("panel: key loss kept from the pieces \(Page.quietsKeyLoss)")
        #else
        _ = Page.quietsKeyLoss
        #endif
        let page = Page()
        page.autoresizingMask = [.width, .height]        // fills the glass, whichever way the glass lays it out
        page.clipsToBounds = true
        let roots = [AnyView(MenuTop())] + PanelView.Tab.allCases.map { AnyView(PanelView.piece($0)) }
        var quiet = false
        for (i, root) in roots.enumerated() {
            let view = root.panelPiece { MenuPanel.shared.measured(i, $0) }
            #if DEMO
            let host = WatchedHost(rootView: view)   // logs what asks it to lay out
            #else
            let host = PieceHost(rootView: view)
            #endif
            heights.append(host.fittingSize.height)   // measured before the hosting view stops sizing anything
            // No say in the window's size: with one, Auto Layout resized the window to each new tab in one frame,
            // and fit() eased nothing (runs 58 to 60). Each piece reports its height instead.
            host.sizingOptions = []
            host.autoresizingMask = [.width]
            host.isHidden = i > 1
            page.addSubview(host)
            pieces.append(host)
            quiet = Page.quietsHidden(host) || quiet
        }
        #if DEMO
        print("panel: global changes kept from hidden pieces \(quiet)")
        #else
        _ = quiet
        #endif
        let size = CGSize(width: PanelView.width, height: heights[0] + heights[1])
        page.frame = CGRect(origin: .zero, size: size)
        frames()
        wanted = size
        let holder = KeyHolder()
        holder.nextKeyView = pieces.first
        zip(pieces, pieces.dropFirst()).forEach { $0.nextKeyView = $1 }   // hidden ones are passed over
        page.addSubview(holder)
        p.initialFirstResponder = holder
        let glass = NSGlassEffectView()
        glass.cornerRadius = 13   // the menu bar's own panel, measured on CI
        glass.contentView = page
        p.contentView = glass
        p.setContentSize(size)
        return p
    }

    /// Shows windows once where nobody sees them, so their first real showing has nothing left to draw, then
    /// runs `done`.
    static func predraw(_ windows: [NSWindow], then done: @escaping () -> Void) {
        Warmth.shared.on = true   // every tab of the reopened window's view, not only the first
        shared.warmLook = look
        // And every tab of the menu bar panel, at full height.
        shared.pieces.forEach { $0.isHidden = false; Page.catchUp($0) }
        shared.panel.setContentSize(CGSize(width: PanelView.width,
                                           height: shared.heights[0] + (shared.heights.dropFirst().max() ?? 0)))
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
            Warmth.shared.on = false
            for w in windows {
                w.orderOut(nil)
                w.alphaValue = 1
            }
            shared.show(shared.tab)
            #if DEMO
            HostListen.report(shared.pieces[1])
            #endif
            done()
        }
    }
}

/// The menu bar panel's top, its tab picker showing MenuPanel's tab. It does not watch the tab: only this picker
/// changes it, and the segmented control shows its own click. Watching, the top was drawn again for every click,
/// 9 to 12 ms of each on macOS 26 (run 45279558852).
private struct MenuTop: View {
    var body: some View {
        let menu = MenuPanel.shared
        PanelView.top(Binding(get: { menu.tab }, set: { menu.show($0) }))
    }
}

/// A hosting view for one of the menu bar panel's pieces. Drawn unseen at 1% (warmIfCold), it takes no clicks.
class PieceHost<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { alphaValue < 0.5 ? nil : super.hitTest(point) }
}

private extension View {
    /// One of the menu bar panel's pieces, its height reported to MenuPanel: through Auto Layout, the hosting view
    /// jumped the window to each new tab's height in one frame (runs 58 to 60), past fit()'s easing. The frame is
    /// the hosting view's height even when the content is taller (minHeight 0), pinned to the top.
    func panelPiece(_ height: @escaping (CGFloat) -> Void) -> some View {
        frame(width: PanelView.width)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                DispatchQueue.main.async { height(h) }
            }
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            // Key whenever it is seen, as a menu is, fading out included: left to the window, its taking and
            // giving up the keyboard as it opened and shut redrew the shown tab for the change.
            .environment(\.appearsActive, true)
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
        panel.appearance = nil   // the look of the moment (makePanel())
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
        // Shut, it keeps the look it was last shown in: a light/dark change laid out and sized its whole view, every
        // tab, in the change's frame (run 45273851193). A reopen shows it in the look of the moment.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { n in
            if let w = n.object as? NSWindow { w.appearance = w.effectiveAppearance }
        }
        return p
    }

    /// How long building and drawing the panels took at launch, for the CI panel demo's notes.
    static var launchNote = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        #if !DEMO
        // Two copies (an old one still running after an update, or one opened from the disk image) would snow
        // twice and fight over the wallpaper: the newest launch wins.
        let me = NSRunningApplication.current
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            where other.processIdentifier != me.processIdentifier { other.terminate() }
        #endif
        let t = CACurrentMediaTime()
        MenuPanel.shared.install()
        let reopen = Self.makePanel()
        reopened = reopen
        MenuPanel.predraw([MenuPanel.shared.panel, reopen]) { [self] in
            reopen.appearance = reopen.effectiveAppearance   // shut from now until a reopen (makePanel())
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
            CrashReport.offerIfAny()
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
        guard alert.suppressionButton?.state == .on else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            let failed = NSAlert()
            failed.messageText = "Windowsill couldn't add itself to Login Items"
            failed.informativeText = "macOS said: \(error.localizedDescription)\n\nTry again with Open at login on "
                + "Windowsill's Settings tab, or add it in System Settings > General > Login Items."
            failed.runModal()
        }
    }
}

#if !DEMO
/// What the CI demo counts of the panel's views redrawing (BodyLog); nothing in a release build.
@inline(__always) func bodyRan(_ name: String) {}
#endif
