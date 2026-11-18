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
    var top: CGFloat { rect.maxY }
}

struct Snapshot {
    var windows: [WinInfo] = []     // front to back
    var surfaces: [Surface] = []    // the Dock, then windows front to back, then each screen's floor
    var dock: CGRect?

    /// Is `p` hidden behind something stacked in front of `s`?
    func isCovered(_ p: CGPoint, behind s: Surface) -> Bool {
        if s.isGround, let d = dock, d.contains(p) { return true }
        return Geo.covered(p, by: windows.prefix(min(s.order, windows.count)).lazy.map(\.frame))
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
        // area then starts above it. Its width comes from its window when that is plausible, else
        // the whole width (some macOS versions report a Dock window that is not the visible strip).
        if let screen = screens.first(where: { $0.visibleFrame.minY > $0.frame.minY + 4 }) {
            let f = screen.frame
            let d = dockWindow.flatMap { $0.intersects(f) && $0.minY <= f.minY + 2 && $0.width <= f.width + 1 ? $0 : nil }
            let rect = CGRect(x: d?.minX ?? f.minX, y: f.minY, width: d?.width ?? f.width,
                              height: screen.visibleFrame.minY - f.minY)
            snap.dock = rect
            snap.surfaces.append(Surface(key: Surface.dockKey, rect: rect, order: 0, cap: dockCap, isGround: false))
        }
        for (i, w) in snap.windows.enumerated() {
            let top = CGPoint(x: w.frame.midX, y: w.frame.maxY - 1)
            let screen = screens.first { $0.frame.contains(top) } ?? screens.first { $0.frame.intersects(w.frame) }
            snap.surfaces.append(Surface(key: w.id, rect: w.frame, order: i, cap: windowCap, isGround: false,
                                         headroom: screen.map { $0.visibleFrame.maxY - w.frame.maxY } ?? .greatestFiniteMagnitude))
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
