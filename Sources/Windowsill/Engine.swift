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

    init(screen: NSScreen, index: Int) {
        self.screen = screen
        frame = screen.frame
        panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.setFrame(frame, display: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)))
        // Deliberately not .fullScreenAuxiliary: a full-screen app gets its Space to itself, and the
        // overlay, being absent there, is reported occluded and pauses.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
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
        panel.orderFrontRegardless()
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
    private(set) var lowPower = false
    private var paused = false
    /// The demo drives a scripted pointer; everything that follows the mouse reads `pointer`.
    var pointerOverride: CGPoint?
    var pointer: CGPoint { pointerOverride ?? NSEvent.mouseLocation }
    /// Decorations that came to rest this tick, so the scene can squash them on landing.
    var landed = Set<UUID>()

    private var lastFrames: [Int: CGRect] = [:]
    private var lastVelocity: [Int: CGVector] = [:]
    /// How hard each window was jerked this tick: the change in its velocity, points per second.
    private var jolt: [Int: CGFloat] = [:]
    private var knockedFrom: [UUID: Int] = [:]
    private var busyUntil: TimeInterval = 0
    private var quietUntil: TimeInterval = 0
    private var evenTick = false
    private var lastTick = CACurrentMediaTime()
    private var nextPowerCheck: TimeInterval = 0
    private var timer: Timer?
    private var bag = Set<AnyCancellable>()
    private var fallSpeed: [UUID: CGFloat] = [:]
    private var dragging: UUID?
    private var lastAllScreens = true
    private var nextVisit: [String: TimeInterval] = [:]
    private static let gravity: CGFloat = 900

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
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) {
            [weak self] _ in self?.refreshPower()
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) {
            [weak self] _ in self?.setPaused(true)
        }
        ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.setPaused(false)
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
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
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
    }

    func refreshPower() {
        lowPower = Self.onBattery() || ProcessInfo.processInfo.isLowPowerModeEnabled
        if state.onBattery != lowPower { state.onBattery = lowPower }
        overlays.forEach { $0.view.preferredFramesPerSecond = lowPower ? 30 : 60 }
    }

    static func onBattery() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() else { return false }
        return (type as String) == "Battery Power"
    }

    private func setPaused(_ p: Bool) {
        paused = p
        applyPause()
    }

    private func applyPause() {
        for o in overlays {
            o.view.isPaused = paused || !o.panel.occlusionState.contains(.visible)
        }
    }

    // MARK: - The tick: 30 Hz at rest, 60 Hz while a window moves so its snow keeps up with it

    private func tick() {
        guard !paused else { return }
        let now = CACurrentMediaTime()
        evenTick.toggle()
        guard evenTick || now < busyUntil else { return }
        let dt = CGFloat(max(1.0 / 120, min(0.2, now - lastTick)))
        lastTick = now
        snap = WindowTracker.snapshot()
        trackWindows(dt: dt, now: now)
        stepDecor(dt: dt)
        updatePassthrough()
        scheduleVisits(now)
        if now > nextPowerCheck {
            nextPowerCheck = now + 30
            refreshPower()
        }
    }

    /// Snow rides a window that moves smoothly. A jolt (a sudden start, stop or change of direction)
    /// shakes a share loose, and that snow keeps the velocity it had, the way anything with inertia
    /// would: a sudden stop throws it forward, a sudden start leaves it behind to fall. A resize drops
    /// what lay past the moved edge; a window that closes or minimises drops everything on it.
    private func trackWindows(dt: CGFloat, now: TimeInterval) {
        var alive = Set<Int>()
        var velocity: [Int: CGVector] = [:]
        jolt.removeAll(keepingCapacity: true)
        for w in snap.windows {
            alive.insert(w.id)
            guard let was = lastFrames[w.id] else { continue }
            let resized = abs(w.frame.width - was.width) > 0.5
            let v = CGVector(dx: resized ? 0 : (w.frame.minX - was.minX) / dt, dy: (w.frame.maxY - was.maxY) / dt)
            let prev = lastVelocity[w.id] ?? .zero
            velocity[w.id] = v
            let dv = hypot(v.dx - prev.dx, v.dy - prev.dy)
            guard was != w.frame || dv > 1 else { continue }
            busyUntil = now + 0.6
            jolt[w.id] = dv
            let shake = Self.shake(dv)
            var fallen: [(x: CGFloat, h: CGFloat)] = []
            if var pile = piles[w.id] {
                fallen = pile.refit(from: was, to: w.frame)
                for (i, h) in pile.shed(shake).enumerated() where h > 0.05 {
                    fallen.append((w.frame.minX + (CGFloat(i) + 0.5) * Pile.bucket, h))
                }
                piles[w.id] = pile.isEmpty ? nil : pile
            }
            for o in overlays where o.frame.intersects(was) || o.frame.intersects(w.frame) {
                o.scene.surfaceMoved(w.id, top: w.frame.maxY, fallen: fallen, velocity: prev, shake: shake)
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
        lastVelocity = velocity
    }

    /// Share of a pile a jolt of `dv` points per second shakes loose: none for the wobble of a steady
    /// drag, all of it for a hard flick.
    static func shake(_ dv: CGFloat) -> CGFloat { min(1, max(0, (dv - 220) / 1800)) }

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
            settled = ride(s.id, x: &s.x, y: &s.y, window: &s.windowId, offset: &s.offsetX, knock: 1500, dt: dt) || settled
            decor.snowmen[i] = s
        }
        for i in decor.presents.indices where !decor.presents[i].anchored && decor.presents[i].id != dragging {
            var g = decor.presents[i]
            var offset = g.offsetX ?? 0
            settled = ride(g.id, x: &g.x, y: &g.y, window: &g.windowId, offset: &offset, knock: 1000, dt: dt) || settled
            g.offsetX = g.windowId == nil ? nil : offset
            decor.presents[i] = g
        }
        if settled { save() }
    }

    /// Keeps an item on its window, or lets it fall. Returns true when it has just come to rest.
    private func ride(_ id: UUID, x: inout CGFloat, y: inout CGFloat, window: inout Int?, offset: inout CGFloat,
                      knock: CGFloat, dt: CGFloat) -> Bool {
        if let wid = window {
            if let w = snap.window(wid), (jolt[wid] ?? 0) < knock {
                x = w.frame.minX + offset
                y = w.frame.maxY
                return false
            }
            if snap.window(wid) != nil { knockedFrom[id] = wid }     // knocked off: don't land straight back
            window = nil
        }
        guard let landed = fall(id, x: x, y: &y, dt: dt) else { return false }
        if landed.key >= 0 {
            window = landed.key
            offset = x - landed.rect.minX
        }
        return true
    }

    /// Mid-air things are drawn in front, like the snow: on the desk the window holes would erase them.
    func isFalling(_ id: UUID) -> Bool { fallSpeed[id] != nil }

    /// One gravity step. Returns the surface when the item has just come to rest on it.
    private func fall(_ id: UUID, x: CGFloat, y: inout CGFloat, dt: CGFloat) -> Surface? {
        guard let floor = snap.support(x: x, y: y, excluding: knockedFrom[id]) else { return nil }
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
        var x = f.midX
        for _ in 0..<40 {
            x = .random(in: (f.minX + f.width * 0.08)...(f.maxX - f.width * 0.08))
            let clearOfDock = snap.dock.map { x < $0.minX - 80 || x > $0.maxX + 80 } ?? true
            if clearOfDock && decor.trees.allSatisfy({ abs($0.x - x) > 170 }) { break }
        }
        let tree = TreeItem(x: x, y: f.minY + (mainScene?.floorY ?? 0))
        state.freshIds.insert(tree.id)
        decor.trees.append(tree)
        save()
    }

    /// Rolls a snowman onto the frontmost window wide enough to hold one, or onto the floor.
    func rollSnowman(onWindow preferred: Int? = nil) {
        guard decor.snowmen.count < 6 else { return }
        let f = mainFrame
        let target = preferred.flatMap { snap.window($0) }
            ?? snap.windows.first { $0.frame.width > 260 && f.contains(CGPoint(x: $0.frame.midX, y: $0.frame.maxY - 1)) }
        var man: SnowmanItem
        if let w = target {
            let x = CGFloat.random(in: (w.frame.minX + 60)...(w.frame.maxX - 60))
            man = SnowmanItem(x: x, y: w.frame.maxY, windowId: w.id, offsetX: x - w.frame.minX)
        } else {
            let x = CGFloat.random(in: (f.minX + 120)...(f.maxX - 120))
            man = SnowmanItem(x: x, y: floorTop(x: x, y: f.maxY) ?? f.minY)
        }
        state.freshIds.insert(man.id)
        decor.snowmen.append(man)
        save()
    }

    func addPresent(at p: CGPoint, anchored: Bool) {
        guard decor.presents.count < 8 else { return }
        let gift = PresentItem(x: p.x, y: p.y, anchored: anchored)
        state.freshIds.insert(gift.id)
        decor.presents.append(gift)
        save()
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
