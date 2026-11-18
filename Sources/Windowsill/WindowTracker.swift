import AppKit

/// One on-screen window, in global Cocoa coordinates.
struct WinInfo {
    let id: Int
    let frame: CGRect
}

/// A top edge that weather and decorations can rest on.
struct Surface {
    static let dockKey = -1
    static func groundKey(_ screen: Int) -> Int { -10 - screen }

    let key: Int
    let rect: CGRect      // global Cocoa; things settle on rect.maxY
    let order: Int        // how many windows are stacked in front of it
    let cap: CGFloat
    let isGround: Bool
    /// Room above the top edge before the menu bar: something taller cannot stand there.
    var headroom: CGFloat = .greatestFiniteMagnitude
    /// Radius of its rounded top corners: snow at the ends follows them down.
    var corner: CGFloat = 0
    var top: CGFloat { rect.maxY }
}

struct Snapshot {
    var windows: [WinInfo] = []     // front to back
    var surfaces: [Surface] = []    // the Dock, then windows front to back, then each screen's floor
    var dock: CGRect?

    /// Is `p` hidden behind something stacked in front of `s`?
    func isCovered(_ p: CGPoint, behind s: Surface) -> Bool {
        // The floor's top is the Dock strip's top, and callers probe just above it: reach a little higher,
        // or snow piles on the floor in mid-air beside the Dock and over its shelf.
        if s.isGround, let d = dock, d.insetBy(dx: 0, dy: -2).contains(p) { return true }
        return Geo.covered(p, by: windows.prefix(min(s.order, windows.count)).lazy.map(\.frame))
    }

    /// The same snapshot with each window in `lead` moved by it, and its surface with it.
    func led(by lead: [Int: CGVector]) -> Snapshot {
        guard !lead.isEmpty else { return self }
        var s = self
        s.windows = windows.map { w in
            lead[w.id].map { WinInfo(id: w.id, frame: w.frame.offsetBy(dx: $0.dx, dy: $0.dy)) } ?? w
        }
        s.surfaces = surfaces.map { f in
            guard !f.isGround, let d = lead[f.key] else { return f }
            return Surface(key: f.key, rect: f.rect.offsetBy(dx: d.dx, dy: d.dy), order: f.order, cap: f.cap,
                           isGround: false, headroom: f.headroom - d.dy, corner: f.corner)
        }
        return s
    }

    func window(_ id: Int) -> WinInfo? { windows.first { $0.id == id } }

    func headroom(of key: Int) -> CGFloat { surfaces.first { $0.key == key }?.headroom ?? .greatestFiniteMagnitude }

    /// The highest uncovered surface at or below `y` under `x` with room for something `height` tall,
    /// other than the one an item was knocked off.
    func support(x: CGFloat, y: CGFloat, excluding skip: Int? = nil, height: CGFloat = 0) -> Surface? {
        var best: Surface?
        for s in surfaces where x >= s.rect.minX && x <= s.rect.maxX && s.top <= y + 1 && s.key != skip
            && s.headroom >= height {
            if let b = best, b.top >= s.top { continue }
            // The ground is always there, even behind a window that reaches it: things land and hide.
            if s.isGround || !isCovered(CGPoint(x: x, y: s.top + 1), behind: s) { best = s }
        }
        return best
    }
}

enum WindowTracker {
    static let windowCap: CGFloat = 14
    static let dockCap: CGFloat = 12
    static let groundCap: CGFloat = 22

    /// Normal app windows (layer 0) plus the Dock and the screen floors. Window bounds need no
    /// Screen Recording permission; only titles and pixels do, and neither is read.
    static func snapshot() -> Snapshot {
        var snap = Snapshot()
        let screens = NSScreen.screens
        guard let primary = screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return snap }
        let primaryH = primary.frame.height
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        var dockWindow: CGRect?

        for info in list {
            guard let id = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let q = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            let r = Geo.cocoa(fromQuartz: q, primaryHeight: primaryH)
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            if layer == dockLevel, owner == "Dock", r.height < 250 { dockWindow = r; continue }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard layer == 0, alpha > 0.05, r.width >= 60, r.height >= 40 else { continue }
            snap.windows.append(WinInfo(id: id, frame: r))
        }

        // The Dock only counts when it sits at the bottom and is not auto-hidden: the screen's usable
        // area then starts above it. The whole strip it reserves hides the floor; snow settles on its
        // shelf, which is only as wide as the Dock (from the window server, else from its window when
        // that is plausible: since macOS 14 the Dock's window covers the screen) and sits a little
        // below the strip's top, with rounded ends.
        if let screen = screens.first(where: { $0.visibleFrame.minY > $0.frame.minY + 4 }) {
            let f = screen.frame
            let strip = CGRect(x: f.minX, y: f.minY, width: f.width, height: screen.visibleFrame.minY - f.minY)
            snap.dock = strip
            func alongBottom(_ r: CGRect) -> Bool {
                let atBottom: Bool = abs(r.minY - f.minY) < 2
                let inside: Bool = r.minX >= f.minX - 1 && r.maxX <= f.maxX + 1
                return atBottom && inside && r.width > 100
            }
            let candidates: [CGRect] = [DockShelf.reserved(primaryHeight: primaryH), dockWindow].compactMap { $0 }
            let span: CGRect? = candidates.first(where: alongBottom)
            let shelf = CGRect(x: span?.minX ?? f.minX, y: f.minY, width: span?.width ?? f.width,
                               height: strip.height - DockShelf.inset)
            snap.surfaces.append(Surface(key: Surface.dockKey, rect: shelf, order: 0, cap: dockCap, isGround: false,
                                         corner: span == nil ? 0 : min(DockShelf.corner, shelf.width / 2)))
        }
        for (i, w) in snap.windows.enumerated() {
            let top = CGPoint(x: w.frame.midX, y: w.frame.maxY - 1)
            let screen = screens.first { $0.frame.contains(top) } ?? screens.first { $0.frame.intersects(w.frame) }
            snap.surfaces.append(Surface(key: w.id, rect: w.frame, order: i, cap: windowCap, isGround: false,
                                         headroom: screen.map { $0.visibleFrame.maxY - w.frame.maxY } ?? .greatestFiniteMagnitude,
                                         corner: Pile.windowCorner))
        }
        // Each screen's floor is the bottom of its usable area: the top of a Dock along the bottom, else
        // the bottom edge. Trees, the train, the Yeti and fallen snow all share that one line.
        for (i, s) in screens.enumerated() {
            let f = s.frame
            snap.surfaces.append(Surface(key: Surface.groundKey(i),
                                         rect: CGRect(x: f.minX, y: s.visibleFrame.minY - 10, width: f.width, height: 10),
                                         order: snap.windows.count, cap: groundCap, isGround: true))
        }
        return snap
    }
}

/// The Dock's shelf. The window server knows the strip the Dock reserves, through a private call looked
/// up at run time; without it the shelf counts as the screen's width.
enum DockShelf {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias GetRect = @convention(c) (Int32, UnsafeMutablePointer<CGRect>, UnsafeMutablePointer<Int32>) -> Int32
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let connection = skyLight.flatMap { dlsym($0, "SLSMainConnectionID") }
        .map { unsafeBitCast($0, to: MainConnection.self)() }
    private static let getRect = skyLight.flatMap { dlsym($0, "SLSGetDockRectWithReason") }
        .map { unsafeBitCast($0, to: GetRect.self) }

    private static let modern = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    /// How far the shelf's top sits below the reserved strip's (2 pt measured on macOS 15).
    static let inset: CGFloat = modern ? 1 : 2
    /// The shelf's corner radius: 16 pt measured on macOS 15; the macOS 26 shelf is rounder (not measured here).
    static let corner: CGFloat = modern ? 22 : 16

    /// The strip the Dock reserves, in global Cocoa coordinates, or nil.
    static func reserved(primaryHeight: CGFloat) -> CGRect? {
        guard let connection, let getRect else { return nil }
        var q = CGRect.zero
        var reason: Int32 = 0
        guard getRect(connection, &q, &reason) == 0, q.width > 0, q.height > 0 else { return nil }
        return Geo.cocoa(fromQuartz: q, primaryHeight: primaryHeight)
    }
}
