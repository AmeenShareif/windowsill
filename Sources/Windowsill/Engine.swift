import AppKit
import SpriteKit
import Combine
import IOKit.ps

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class OverlayView: SKView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One transparent, click-through window per screen, above every app and the Dock.
final class Overlay {
    let screen: NSScreen
    let frame: CGRect
    let panel: OverlayPanel
    let view: OverlayView
    let scene: WeatherScene
    /// The scene's frame count at the last stall check (-1 while paused), how many checks in a row
    /// found it drawing nothing, and how often the view was restarted for it.
    var checkedFrames = -1
    var stalls = 0
    private(set) var restarts = 0

    init(screen: NSScreen, index: Int) {
        self.screen = screen
        // Everything happens below the menu bar: the overlay stops at its bottom edge, so nothing we draw
        // (snow, piles, a snowman on a window just under it) ever covers its menus or icons.
        var f = screen.frame
        f.size.height = screen.visibleFrame.maxY - f.minY
        frame = f
        panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.setFrame(frame, display: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        view = OverlayView(frame: CGRect(origin: .zero, size: frame.size))
        view.allowsTransparency = true
        view.ignoresSiblingOrder = true
        scene = WeatherScene(size: frame.size, origin: frame.origin, screenIndex: index)
        view.presentScene(scene)
        panel.contentView = view
        configure(AppState.shared)
    }

    func configure(_ st: AppState) {
        // In front of every window, or behind them all but over the desktop icons, so snow still
        // settles on window tops and decorations can still be picked up off the desktop.
        let level: CGWindowLevelKey = st.behindWindows ? .desktopIconWindow : .statusWindow
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(level)) + (st.behindWindows ? 1 : 0))
        // Without .fullScreenAuxiliary a full-screen app gets its Space to itself, and the overlay,
        // being absent there, is reported occluded and pauses.
        var b: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if st.overFullScreen { b.insert(.fullScreenAuxiliary) }
        panel.collectionBehavior = b
        panel.sharingType = st.inScreenshots ? .readOnly : .none
        panel.orderFrontRegardless()
    }

    /// SpriteKit can stop calling the scene's update while the view is neither paused nor hidden (seen on
    /// macOS 27): the weather freezes mid-air. A view that drew nothing for a whole check is woken by
    /// pausing it and going on again, and if that did not do it, by taking it out of its window and back.
    func restartIfStalled() {
        let frames = scene.frameCount
        defer { checkedFrames = view.isPaused ? -1 : frames }
        guard !view.isPaused, frames == checkedFrames else { stalls = 0; return }
        stalls += 1
        restarts += 1
        if stalls % 2 == 1 {
            view.isPaused = true
            view.isPaused = false
        } else {
            panel.contentView = nil
            panel.contentView = view
        }
    }

    func close() {
        view.presentScene(nil)
        panel.orderOut(nil)
        panel.close()
    }
}

/// Owns the window snapshot, the snow piles and the decorations; the scenes draw them.
final class Engine {
    static let shared = Engine()

    let state = AppState.shared
    private(set) var overlays: [Overlay] = []
    private(set) var snap = Snapshot()
    var piles: [Int: Pile] = [:]
    private(set) var decor = Decor()
    var pileBoost: CGFloat = 1          // the CI demo speeds up accumulation
    var meltBoost: CGFloat = 1          // and melting
    private(set) var lowPower = false
    /// Why the weather is stopped (the display asleep, the screen locked); it runs when this is empty.
    private var pauses = Set<String>()
    private var paused: Bool { !pauses.isEmpty }
    private var lastLook: [Bool] = []
    /// The demo drives a scripted pointer; everything that follows the mouse reads `pointer`.
    var pointerOverride: CGPoint?
    var pointer: CGPoint { pointerOverride ?? NSEvent.mouseLocation }
    /// Decorations that came to rest this tick, so the scene can squash them on landing.
    var landed = Set<UUID>()

    private var lastFrames: [Int: CGRect] = [:]
    private var motions: [Int: Motion] = [:]
    /// The sway of the snow (and leaves) on each window that moved lately, read by the scenes as they draw.
    private(set) var sways: [Int: Sway] = [:]
    /// How hard each window was jerked this tick: the change in its velocity, points per second.
    private var jolt: [Int: CGFloat] = [:]
    private var knockedFrom: [UUID: Int] = [:]
    /// Each tick a window moved, as the tracker saw it (the demo turns it on), to set against the video.
    var trace: [String]?
    private var busyUntil: TimeInterval = 0
    private var quietUntil: TimeInterval = 0
    private var evenTick = false
    private var lastTick = CACurrentMediaTime()
    private var lastFrame: TimeInterval = 0
    /// Run at the start of every frame, before the windows are read, until one returns false. The demo
    /// moves its windows here, so they move in step with the display the way a dragged window does.
    var everyFrame: [() -> Bool] = []
    private var nextPowerCheck: TimeInterval = 0
    private var nextStallCheck: TimeInterval = 0
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var fallSpeed: [UUID: CGFloat] = [:]
    private var dragging: UUID?
    private var lastAllScreens = true
    private var nextVisit: [String: TimeInterval] = [:]
    private var shuffling = false
    private static let gravity: CGFloat = 900
    /// How fast two things set down too close shuffle apart, points per second each.
    private static let shuffle: CGFloat = 110
    /// What rides a moving window is drawn this far ahead of where it was read, for the frame the overlay
    /// takes to reach the screen. Two frames covered windows read on a timer, up to 80 ms stale (CI,
    /// 2026-11-19); read at the start of each frame, they are not.
    private static let drawLag: CGFloat = 1.0 / 60

    var mainScene: WeatherScene? { overlays.first?.scene }

    func start() {
        decor = state.decor
        lastAllScreens = state.allScreens
        rebuildOverlays()
        refreshPower()

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
            [weak self] _ in self?.rebuildOverlays()
        }
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refreshPower() }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
            [weak self] _ in self?.setPaused(true, "asleep")
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.setPaused(false, "asleep")
        }
        // Nobody sees the weather behind the lock screen.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) {
            [weak self] _ in self?.setPaused(true, "locked")
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) {
            [weak self] _ in self?.setPaused(false, "locked")
        }
        // Switching Spaces takes every window away at once; their snow should not rain down from nothing.
        ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.quietUntil = CACurrentMediaTime() + 1.5
        }
        state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.settingsChanged() }
        }.store(in: &bag)

        let now = CACurrentMediaTime()
        nextVisit = ["santa": now + .random(in: 240...480), "train": now + .random(in: 300...600),
                     "yeti": now + .random(in: 420...900)]
        // The scenes drive the engine (frame()); this stands in while none draws: all paused, or one
        // stalled, which tick then notices and restarts.
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, CACurrentMediaTime() - self.lastFrame > 0.1 else { return }
            self.beat()
        }
        RunLoop.main.add(t, forMode: .common)   // keep ticking while a window is being dragged
        timer = t
        WallpaperManager.shared.start()
    }

    // MARK: - Screens, power, pausing

    func rebuildOverlays() {
        overlays.forEach { $0.close() }
        let screens = state.allScreens ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        overlays = screens.enumerated().map { Overlay(screen: $0.element, index: $0.offset) }
        for o in overlays {
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                   object: o.panel, queue: .main) { [weak self] _ in
                self?.applyPause()
            }
        }
        applyPause()
    }

    private func settingsChanged() {
        if state.allScreens != lastAllScreens {
            lastAllScreens = state.allScreens
            rebuildOverlays()
        }
        let look = [state.behindWindows, state.overFullScreen, state.inScreenshots]
        if look != lastLook {
            lastLook = look
            overlays.forEach { $0.configure(state) }
            applyPause()
        }
    }

    func refreshPower() {
        let info = ProcessInfo.processInfo
        let note: String? = info.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? "Your Mac is running hot"
            : info.isLowPowerModeEnabled ? "Low Power Mode is on"
            : Self.onBattery() ? "On battery" : nil
        lowPower = note != nil
        if state.powerNote != note { state.powerNote = note }
        overlays.forEach { $0.view.preferredFramesPerSecond = lowPower ? 30 : 60 }
    }

    static func onBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() else { return false }
        return (type as String) == "Battery Power"
    }

    private func setPaused(_ p: Bool, _ why: String) {
        if p { pauses.insert(why) } else { pauses.remove(why) }
        applyPause()
    }

    private func applyPause() {
        for o in overlays {
            o.view.isPaused = paused || !o.panel.occlusionState.contains(.visible)
        }
    }

    // MARK: - The tick: every other frame at rest, every frame while a window moves so its snow keeps up

    /// Each scene calls this as it starts a frame. Read on a 60 Hz timer instead, a window's place was
    /// 8-80 ms old on a busy Mac, and its snow trailed it, then ran on past it at a stop (CI, 2026-11-19).
    func frame() {
        let now = CACurrentMediaTime()
        guard now - lastFrame > 0.008 else { return }     // another screen's scene read them this frame
        lastFrame = now
        beat()
    }

    private func beat() {
        let hooks = everyFrame
        everyFrame = []
        let kept = hooks.filter { $0() }                  // a hook may add the next (a shake's next stroke)
        everyFrame = kept + everyFrame
        tick()
    }

    private func tick() {
        guard !paused else { return }
        let now = CACurrentMediaTime()
        evenTick.toggle()
        guard evenTick || now < busyUntil else { return }
        let dt = CGFloat(max(1.0 / 120, min(0.2, now - lastTick)))
        lastTick = now
        snap = WindowTracker.snapshot()
        trackWindows(dt: dt, now: now)
        if state.melt && state.effect == .snow {
            for key in Array(piles.keys) {
                piles[key]?.melt(dt * meltBoost)
                if piles[key]?.isEmpty == true { piles[key] = nil }
            }
        }
        stepDecor(dt: dt)
        updatePassthrough()
        scheduleVisits(now)
        if now > nextPowerCheck {
            nextPowerCheck = now + 30
            refreshPower()
        }
        if now > nextStallCheck {
            nextStallCheck = now + 1
            overlays.forEach { $0.restartIfStalled() }
        }
    }

    /// Snow rides a window that moves smoothly. A jolt (a sudden start, stop or change of direction)
    /// shakes a share loose, and that snow keeps the velocity it had, the way anything with inertia
    /// would: a sudden stop throws it forward, a sudden start leaves it behind to fall. A resize drops
    /// what lay past the moved edge; a window that closes or minimises drops everything on it.
    private func trackWindows(dt: CGFloat, now: TimeInterval) {
        var alive = Set<Int>()
        jolt.removeAll(keepingCapacity: true)
        for w in snap.windows {
            alive.insert(w.id)
            guard let was = lastFrames[w.id] else { continue }
            // A resize from the left moves minX, but it is not a shove.
            var m = motions[w.id] ?? Motion()
            let resized = abs(w.frame.width - was.width) > 0.5
            let moved = CGVector(dx: resized ? 0 : w.frame.minX - was.minX, dy: w.frame.maxY - was.maxY)
            let (dv, prev) = m.add(moved: moved, at: now)
            motions[w.id] = m
            // A nudge does not throw the snow off: it sways as the window starts and stops and settles a
            // beat later, and only what leans out past an end tips over it.
            if sways[w.id] != nil || m.velocity != .zero {
                var s = sways[w.id] ?? Sway()
                let swaying = s.step(window: m.velocity, dt: dt)
                sways[w.id] = swaying ? s : nil
                if swaying { busyUntil = max(busyUntil, now + 0.1) }
                let tipped = spill(w.id, frame: w.frame, lean: s.offset.dx, dt: dt)
                if !tipped.isEmpty {
                    let v = CGVector(dx: m.velocity.dx + s.offset.dx * 12, dy: m.velocity.dy)
                    for o in overlays where o.frame.intersects(w.frame) {
                        o.scene.surfaceMoved(w.id, top: w.frame.maxY, fallen: tipped, velocity: v, shake: 0)
                    }
                }
            }
            if (trace?.count ?? .max) < 600, was != w.frame || m.velocity != .zero {
                let a = m.ahead(Self.drawLag)
                trace?.append(String(format: "%.3f", now) + " win \(w.id) x \(Int(w.frame.minX)) top \(Int(w.frame.maxY)) "
                              + "lead \(Int(a.dx)),\(Int(a.dy)) jolt \(Int(dv))")
            }
            guard was != w.frame || dv > 1 else { continue }
            busyUntil = now + 0.6
            jolt[w.id] = dv
            let shake = Motion.shake(dv, dt: dt)
            var fallen: [(x: CGFloat, h: CGFloat)] = []
            if var pile = piles[w.id] {
                fallen = pile.refit(from: was, to: w.frame)
                for (i, h) in pile.shed(shake).enumerated() where h > 0.05 {
                    fallen.append((w.frame.minX + (CGFloat(i) + 0.5) * Pile.bucket, h))
                }
                piles[w.id] = pile.isEmpty ? nil : pile
            }
            // Snow shaken off at a dead stop leaves from where it lay: led by the speed the window just lost,
            // it was born up to 50 pt ahead and flew on as a level line of the pile's outline (CI, 2026-11-18).
            let d = moved == .zero ? .zero : m.ahead(Self.drawLag)
            let shown = fallen.map { (x: $0.x + d.dx, h: $0.h) }
            for o in overlays where o.frame.intersects(was) || o.frame.intersects(w.frame) {
                o.scene.surfaceMoved(w.id, top: w.frame.maxY + d.dy, fallen: shown, velocity: prev, shake: shake)
            }
        }
        let quiet = now < quietUntil
        for (key, was) in lastFrames where !alive.contains(key) {
            let pile = piles.removeValue(forKey: key)
            let fallen: [(x: CGFloat, h: CGFloat)] = quiet ? [] : (pile?.heights ?? []).enumerated().compactMap { i, h in
                h > 0.05 ? (x: was.minX + (CGFloat(i) + 0.5) * Pile.bucket, h: h) : nil
            }
            overlays.forEach { $0.scene.surfaceGone(key, top: was.maxY, fallen: fallen, quiet: quiet) }
        }
        lastFrames = Dictionary(snap.windows.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        motions = motions.filter { alive.contains($0.key) }
        sways = sways.filter { alive.contains($0.key) }
        // Everything after this (the scenes, the decorations) sees a moving window where it will be on
        // screen, so its snow, the cut around it and what stands on it keep up with a drag or a shake.
        snap = snap.led(by: motions.compactMapValues { $0.velocity == .zero ? nil : $0.ahead(Self.drawLag) })
    }

    /// Snow leaning more than 7 pt past its window's end (Sway.reach is 10; a move faster than ~250 pt/s)
    /// tips off the three buckets at that end, faster the further it leans; the rest of the pile stays put,
    /// so a slight move sways the snow without dropping any.
    private func spill(_ key: Int, frame: CGRect, lean: CGFloat, dt: CGFloat) -> [(x: CGFloat, h: CGFloat)] {
        guard abs(lean) > 7, var pile = piles[key] else { return [] }
        let f = min(0.3, (abs(lean) - 7) * 3 * dt)
        let n = pile.heights.count
        var out: [(x: CGFloat, h: CGFloat)] = []
        for i in (lean < 0 ? 0..<min(3, n) : max(0, n - 3)..<n) where pile.heights[i] * f > 0.05 {
            let x = (CGFloat(i) + 0.5) * Pile.bucket
            out.append((frame.minX + x, pile.take(at: x, keep: 1 - f)))
        }
        piles[key] = pile.isEmpty ? nil : pile
        return out
    }

    private func updatePassthrough() {
        let m = pointer
        for o in overlays {
            let local = CGPoint(x: m.x - o.frame.minX, y: m.y - o.frame.minY)
            let want = o.frame.contains(m) && o.scene.wantsMouse(at: local)
            if o.panel.ignoresMouseEvents == want { o.panel.ignoresMouseEvents = !want }
        }
    }

    private func scheduleVisits(_ now: TimeInterval) {
        guard state.showDecor, let scene = mainScene else { return }
        for (kind, at) in nextVisit where now > at {
            nextVisit[kind] = now + .random(in: 360...900)
            switch kind {
            case "santa" where state.santaVisits: scene.callSanta()
            case "train" where state.trainVisits && !decor.trees.isEmpty: scene.sendTrain()
            case "yeti" where state.yetiVisits && !decor.snowmen.isEmpty: scene.summonYeti()
            default: break
            }
        }
    }

    // MARK: - Decorations

    /// Snowmen and presents ride the window they stand on. A hard enough jolt knocks them off (a present,
    /// being lighter, goes first); then, like anything unsupported, they fall.
    private func stepDecor(dt: CGFloat) {
        landed.removeAll(keepingCapacity: true)
        var settled = false
        // A tree let go of in mid-air drops to the floor; it never stands on a window.
        for i in decor.trees.indices where decor.trees[i].id != dragging {
            var t = decor.trees[i]
            guard let floor = floorTop(x: t.x, y: t.y) else { continue }
            if drop(t.id, y: &t.y, to: floor, dt: dt) {
                landed.insert(t.id)
                settled = true
            }
            if t.y != decor.trees[i].y { decor.trees[i] = t }
        }
        for i in decor.snowmen.indices where decor.snowmen[i].id != dragging {
            var s = decor.snowmen[i]
            if s.windowId == nil { s.x = clearOfTrees(s.id, x: s.x, y: s.y, dt: dt) }
            settled = ride(s.id, x: &s.x, y: &s.y, window: &s.windowId, offset: &s.offsetX, knock: 1500,
                           height: Art.snowmanSize.height, dt: dt) || settled
            decor.snowmen[i] = s
        }
        for i in decor.presents.indices where !decor.presents[i].anchored && decor.presents[i].id != dragging {
            var g = decor.presents[i]
            var offset = g.offsetX ?? 0
            settled = ride(g.id, x: &g.x, y: &g.y, window: &g.windowId, offset: &offset, knock: 1000,
                           height: Art.presentSize.height, dt: dt) || settled
            g.offsetX = g.windowId == nil ? nil : offset
            decor.presents[i] = g
        }
        let wasShuffling = shuffling
        shuffling = makeRoom(dt: dt)
        if settled || (wasShuffling && !shuffling) { save() }
    }

    /// Something set down where another already stands shuffles aside, the two a little each, until they
    /// no longer overlap: they are never drawn inside each other. A window's ends hold them; pushed off the
    /// end of the Dock, one falls. A tree never moves: a snowman that lands in front of its trunk steps out
    /// to the side. Returns true while anything is still moving.
    private func makeRoom(dt: CGFloat) -> Bool {
        typealias Body = (man: Bool, i: Int, x: CGFloat, y: CGFloat, window: Int?, half: CGFloat)
        var bodies: [Body] = []
        for (i, m) in decor.snowmen.enumerated() where m.id != dragging && fallSpeed[m.id] == nil {
            // Half the drawn width, not the footprint, and a little more: side by side their arms touched.
            bodies.append((true, i, m.x, m.y, m.windowId, Art.snowmanSize.width / 2 + 3))
        }
        for (i, g) in decor.presents.enumerated() where !g.anchored && g.id != dragging && fallSpeed[g.id] == nil {
            bodies.append((false, i, g.x, g.y, g.windowId, Art.presentSize.width / 2))
        }
        let trees = Set(bodies.count..<(bodies.count + decor.trees.count))
        for t in decor.trees { bodies.append((false, -1, t.x, t.y, nil, Self.treeHalf)) }
        let push = shoves(bodies.map { $0.x }, halves: bodies.map { $0.half }, fixed: trees,
                          limit: Self.shuffle * dt) { a, b in
            // A present may lie under a tree; only a snowman is stepped out of one.
            let p = bodies[a], q = bodies[b]
            guard (p.i >= 0 || q.man) && (q.i >= 0 || p.man) else { return false }
            return p.window == q.window && (p.window != nil || abs(p.y - q.y) < 4)
        }
        var moved = false
        let step = Self.shuffle * dt
        for (k, p) in bodies.enumerated() where p.i >= 0 && (push[k] != 0 || p.window != nil) {
            let frame = p.window.flatMap { snap.window($0)?.frame }
            var x = p.x + push[k]
            if let f = frame {
                let lo = f.minX + p.half, hi = max(f.maxX - p.half, lo)
                // Landed half over a window's end, it steps back on rather than stand on air (CI, 2026-11-19).
                x = p.x < lo ? min(p.x + step, lo) : p.x > hi ? max(p.x - step, hi) : min(max(x, lo), hi)
            }
            guard abs(x - p.x) > 0.01 else { continue }      // held by a window's end: the other one moves
            moved = true
            if p.man {
                decor.snowmen[p.i].x = x
                if let f = frame { decor.snowmen[p.i].offsetX = x - f.minX }
            } else {
                decor.presents[p.i].x = x
                if let f = frame { decor.presents[p.i].offsetX = x - f.minX }
            }
        }
        return moved
    }

    private static let treeHalf: CGFloat = 70
    /// How fast a falling snowman drifts out from in front of a tree, points per second.
    private static let drift: CGFloat = 160

    /// A snowman falling to the floor in front of a tree drifts out to the side on the way down, where there
    /// is room, rather than land over its baubles and only then step out (CI, 2026-11-19).
    private func clearOfTrees(_ id: UUID, x: CGFloat, y: CGFloat, dt: CGFloat) -> CGFloat {
        let half = Art.snowmanSize.width / 2 + 3
        guard let floor = snap.support(x: x, y: y, excluding: knockedFrom[id], height: Art.snowmanSize.height),
              floor.isGround, y > floor.top + 0.5,
              let tree = decor.trees.filter({ abs($0.y - floor.top) < 4 }).min(by: { abs($0.x - x) < abs($1.x - x) }),
              abs(tree.x - x) < Self.treeHalf + half else { return x }
        let lo = floor.rect.minX + half, hi = floor.rect.maxX - half
        let sides: [CGFloat] = x < tree.x ? [-1, 1] : [1, -1]
        guard let goal = sides.map({ tree.x + $0 * (Self.treeHalf + half) }).first(where: { $0 >= lo && $0 <= hi })
        else { return x }
        let step = Self.drift * dt
        return goal < x ? max(goal, x - step) : min(goal, x + step)
    }

    /// Keeps an item on its window, or lets it fall. Returns true when it has just come to rest.
    /// A window raised until the item meets the menu bar knocks it off, like a jolt.
    private func ride(_ id: UUID, x: inout CGFloat, y: inout CGFloat, window: inout Int?, offset: inout CGFloat,
                      knock: CGFloat, height: CGFloat, dt: CGFloat) -> Bool {
        if let wid = window {
            if let w = snap.window(wid), (jolt[wid] ?? 0) < knock, snap.headroom(of: wid) >= height {
                x = w.frame.minX + offset
                y = w.frame.maxY
                return false
            }
            if snap.window(wid) != nil { knockedFrom[id] = wid }     // knocked off: don't land straight back
            window = nil
        }
        guard let landed = fall(id, x: x, y: &y, height: height, dt: dt) else { return false }
        if landed.key >= 0 {
            window = landed.key
            offset = x - landed.rect.minX
        }
        return true
    }

    /// Mid-air things tumble, and drop behind the windows they pass.
    func isFalling(_ id: UUID) -> Bool { fallSpeed[id] != nil }

    /// The window a falling item was knocked off, until it lands: it falls in front of that one.
    func fellFrom(_ id: UUID) -> Int? { knockedFrom[id] }

    /// One gravity step. Returns the surface when the item has just come to rest on it.
    private func fall(_ id: UUID, x: CGFloat, y: inout CGFloat, height: CGFloat, dt: CGFloat) -> Surface? {
        guard let floor = snap.support(x: x, y: y, excluding: knockedFrom[id], height: height) else { return nil }
        return drop(id, y: &y, to: floor.top, dt: dt) ? touchDown(id, on: floor) : nil
    }

    /// One gravity step toward `floor`. True on the step the item comes to rest there.
    private func drop(_ id: UUID, y: inout CGFloat, to floor: CGFloat, dt: CGFloat) -> Bool {
        if y <= floor + 0.5 {
            y = floor
            return fallSpeed.removeValue(forKey: id) != nil
        }
        let v = (fallSpeed[id] ?? 0) + Self.gravity * dt
        fallSpeed[id] = v
        y = max(floor, y - v * dt)
        guard y == floor else { return false }
        fallSpeed[id] = nil
        return true
    }

    /// The floor under global `x` for something at height `y`: the nearest screen floor at or below it,
    /// else the lowest one (something below every floor is lifted onto it).
    func floorTop(x: CGFloat, y: CGFloat) -> CGFloat? {
        let tops = snap.surfaces.filter { $0.isGround && x >= $0.rect.minX && x <= $0.rect.maxX }.map(\.top)
        return tops.filter { $0 <= y + 1 }.max() ?? tops.min()
    }

    private func touchDown(_ id: UUID, on s: Surface) -> Surface {
        knockedFrom[id] = nil
        landed.insert(id)
        return s
    }

    func save() { state.decor = decor }

    private var mainFrame: CGRect { overlays.first?.frame ?? NSScreen.screens.first?.frame ?? .zero }

    func growTree() {
        guard decor.trees.count < 3 else { return }
        let f = mainFrame
        // Room at either end for the train's engine to come into view in front of it (a tree is 140 wide):
        // with a Dock as wide as the screen the trees went to the ends, and no train came (CI, 2026-11-19).
        let end = min(f.width * 0.3, max(f.width * 0.08, Art.locoSize.width + 90))
        let spots = (0..<40).map { _ in CGFloat.random(in: (f.minX + end)...(f.maxX - end)) }
        func room(_ x: CGFloat) -> CGFloat { decor.trees.map { abs($0.x - x) }.min() ?? .infinity }
        let clearOfDock = { (x: CGFloat) in self.snap.dock.map { x < $0.minX - 80 || x > $0.maxX + 80 } ?? true }
        // A Dock as wide as the screen leaves no spot clear of it: then the one farthest from the other trees,
        // never the last random guess, which could stand inside one.
        let x = spots.first { clearOfDock($0) && room($0) > 170 } ?? spots.max { room($0) < room($1) } ?? f.midX
        let tree = TreeItem(x: x, y: f.minY + (mainScene?.floorY ?? 0))
        state.freshIds.insert(tree.id)
        decor.trees.append(tree)
        save()
    }

    /// Starts rolling a snowman out of snow that has settled: on the preferred surface if it can, else
    /// the frontmost window in sight with room above it below the menu bar, else the Dock, else the floor.
    /// Returns why it can't, for the panel to say.
    @discardableResult
    func rollSnowman(on preferred: Int? = nil) -> String? {
        guard let scene = mainScene else { return nil }
        let building = scene.visitors.compactMap { $0 as? SnowmanBuild }
        guard decor.snowmen.count + building.count < 6 else { return "Six snowmen is the most there's room for." }
        guard state.effect == .snow && state.enabled else { return "A snowman needs snow: choose Snow under Weather and let some settle." }
        let f = mainFrame
        let tall = Art.snowmanSize.height
        var keys = snap.windows.filter { w in
            guard let s = snap.surfaces.first(where: { $0.key == w.id }) else { return false }
            return w.frame.width > 160 && s.headroom >= tall && f.contains(CGPoint(x: w.frame.midX, y: w.frame.maxY - 1))
                && !snap.isCovered(CGPoint(x: w.frame.midX, y: s.top + 1), behind: s)
        }.map(\.id) + [Surface.dockKey, Surface.groundKey(scene.screenIndex)]
        if let p = preferred, let i = keys.firstIndex(of: p) { keys.insert(keys.remove(at: i), at: 0) }
        for key in keys {
            guard let s = snap.surfaces.first(where: { $0.key == key }), s.rect.intersects(f), s.headroom >= tall,
                  let pile = piles[key] else { continue }
            let walls = snowWalls(on: s, building: building)
            if let plan = pile.snowmanPlan(need: SnowmanBuild.need, gap: SnowmanBuild.gap, footprint: SnowmanBuild.footprint,
                                           keep: SnowmanBuild.keep, blocked: walls) {
                scene.visitors.append(SnowmanBuild(plan, on: s, in: scene))
                return nil
            }
        }
        return "Not enough snow has settled to roll one yet: let it pile up on a window or the Dock."
    }

    /// Local xs along surface `s` that a snowball may not roll over: its rounded corners, snow hidden
    /// behind a window in front, and room around everything already standing there.
    private func snowWalls(on s: Surface, building: [SnowmanBuild]) -> (CGFloat) -> Bool {
        let reach = SnowmanBuild.bottomR + 4
        var taken: [ClosedRange<CGFloat>] = building.filter { $0.key == s.key }.map(\.claim)
        func add(_ x: CGFloat, _ y: CGFloat, window: Int?, half: CGFloat) {
            let here = s.isGround || s.key == Surface.dockKey ? window == nil && abs(y - s.top) <= 4 : window == s.key
            let lx = x - s.rect.minX
            if here && lx > -half - reach && lx < s.rect.width + half + reach { taken.append((lx - half - reach)...(lx + half + reach)) }
        }
        for m in decor.snowmen { add(m.x, m.y, window: m.windowId, half: SnowmanBuild.footprint) }
        for g in decor.presents { add(g.x, g.y, window: g.windowId, half: Art.presentSize.width / 2) }
        for t in decor.trees { add(t.x, t.y, window: nil, half: 72) }
        // Nor under a train standing on the Dock or the floor.
        if s.key < 0, let scene = mainScene {
            for case let train as TrainVisit in scene.visitors {
                let off = scene.screenRect.minX - s.rect.minX
                taken.append((train.span.lowerBound + off - reach)...(train.span.upperBound + off + reach))
            }
        }
        let snap = snap, corner = s.corner, w = s.rect.width
        return { x in
            x < corner || x > w - corner || taken.contains { $0.contains(x) }
                || snap.isCovered(CGPoint(x: s.rect.minX + x, y: s.top + 1), behind: s)
        }
    }

    /// Takes all but `keep` of the snow lying on surface `key` at global x; returns how deep it lay.
    @discardableResult
    func takeSnow(on key: Int, at gx: CGFloat, keep: CGFloat) -> CGFloat {
        guard var pile = piles[key], let s = snap.surfaces.first(where: { $0.key == key }),
              gx >= s.rect.minX, gx <= s.rect.maxX else { return 0 }
        let got = pile.take(at: gx - s.rect.minX, keep: keep)
        piles[key] = pile.isEmpty ? nil : pile
        return got
    }

    /// How deep the snow lies on surface `key` at global x.
    func snowDepth(on key: Int, at gx: CGFloat) -> CGFloat {
        guard let pile = piles[key], let s = snap.surfaces.first(where: { $0.key == key }) else { return 0 }
        return pile.height(at: gx - s.rect.minX)
    }

    /// A snowman rolled from snow, standing at global x on surface `s`. The scene pops its face on.
    func placeSnowman(at x: CGFloat, on s: Surface) {
        let man = s.key >= 0 ? SnowmanItem(x: x, y: s.top, windowId: s.key, offsetX: x - s.rect.minX)
                             : SnowmanItem(x: x, y: s.top)
        state.freshIds.insert(man.id)
        decor.snowmen.append(man)
        save()
    }

    func addPresent(at p: CGPoint, anchored: Bool) {
        add(PresentItem(x: p.x, y: p.y, anchored: anchored), pop: true)
    }

    /// `pop`: it appears with a spring; a present thrown into place arrives on its own.
    @discardableResult
    func add(_ gift: PresentItem, pop: Bool) -> Bool {
        guard decor.presents.count < 8 else { return false }
        if pop { state.freshIds.insert(gift.id) }
        decor.presents.append(gift)
        save()
        return true
    }

    func addSnowman(at p: CGPoint) {
        decor.snowmen.append(SnowmanItem(x: p.x, y: p.y))
        save()
    }

    func addOrnament(_ o: Ornament, to tree: UUID) {
        guard let i = decor.trees.firstIndex(where: { $0.id == tree }) else { return }
        if o.kind == .star { decor.trees[i].ornaments.removeAll { $0.kind == .star } }
        guard decor.trees[i].ornaments.count < 60 else { return }
        decor.trees[i].ornaments.append(o)
        save()
    }

    func removeOrnament(at index: Int, from tree: UUID) {
        guard let i = decor.trees.firstIndex(where: { $0.id == tree }),
              decor.trees[i].ornaments.indices.contains(index) else { return }
        decor.trees[i].ornaments.remove(at: index)
        save()
    }

    func remove(_ id: UUID) {
        decor.trees.removeAll { $0.id == id }
        decor.snowmen.removeAll { $0.id == id }
        decor.presents.removeAll { $0.id == id }
        fallSpeed[id] = nil
        save()
    }

    /// Opening a present hangs a new bauble on the nearest tree.
    func openPresent(_ id: UUID) {
        guard let gift = decor.presents.first(where: { $0.id == id }) else { return }
        remove(id)
        let near = decor.trees.min { hypot($0.x - gift.x, $0.y - gift.y) < hypot($1.x - gift.x, $1.y - gift.y) }
        if let tree = near { addOrnament(Ornament.randomBauble(), to: tree.id) }
    }

    func clearDecor() {
        decor = Decor()
        fallSpeed.removeAll()
        save()
    }

    func beginDrag(_ id: UUID) {
        dragging = id
        fallSpeed[id] = nil
        knockedFrom[id] = nil
    }

    var draggingId: UUID? { dragging }

    func drag(_ id: UUID, to p: CGPoint) {
        if let i = decor.trees.firstIndex(where: { $0.id == id }) {
            decor.trees[i].x = p.x; decor.trees[i].y = p.y
        } else if let i = decor.snowmen.firstIndex(where: { $0.id == id }) {
            decor.snowmen[i].x = p.x; decor.snowmen[i].y = p.y
            decor.snowmen[i].windowId = nil
        } else if let i = decor.presents.firstIndex(where: { $0.id == id }) {
            decor.presents[i].x = p.x; decor.presents[i].y = p.y
            decor.presents[i].anchored = false
            decor.presents[i].windowId = nil
        }
    }

    func endDrag() {
        dragging = nil
        save()
    }

    /// The Yeti takes a snowman with it.
    func take(_ id: UUID) -> SnowmanItem? {
        guard let man = decor.snowmen.first(where: { $0.id == id }) else { return nil }
        remove(id)
        return man
    }
}

extension Ornament {
    static let palette: [NSColor] = [
        NSColor(red: 0.86, green: 0.13, blue: 0.18, alpha: 1), NSColor(red: 0.98, green: 0.76, blue: 0.2, alpha: 1),
        NSColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1), NSColor(red: 0.85, green: 0.87, blue: 0.92, alpha: 1),
        NSColor(red: 0.62, green: 0.3, blue: 0.86, alpha: 1), NSColor(red: 0.95, green: 0.42, blue: 0.7, alpha: 1),
    ]

    /// A bauble somewhere inside the tree's silhouette.
    static func randomBauble() -> Ornament {
        var p = CGPoint(x: 0, y: 60)
        for _ in 0..<200 {
            let c = CGPoint(x: .random(in: -60...60), y: .random(in: 26...185))
            if TreeShape.contains(c) { p = c; break }
        }
        return Ornament(kind: .bauble, x: p.x, y: p.y, color: Int.random(in: 0..<palette.count))
    }
}
