import AppKit
import SpriteKit

#if DEMO
/// Where every decoration and visitor is at a demo shot, and anything out of place: standing on air, hanging
/// past a window's end, reaching into the menu bar, or off every screen. A shot that looks fine can still hide
/// one of these; the audit line says so in words.
extension Engine {
    func boundaryAudit() -> [String] {
        let screens = NSScreen.screens
        var counts: [String: Int] = [:]
        var odd: [String] = []
        func note(_ kind: String, _ id: UUID, _ x: CGFloat, _ y: CGFloat, window: Int?, height: CGFloat) {
            let name = "\(kind) \(id.uuidString.prefix(4)) at (\(Int(x)), \(Int(y)))"
            if draggingId == id { counts["carried", default: 0] += 1; return }
            if isFalling(id) { counts["falling", default: 0] += 1; return }
            // As if its display were unplugged: rehomeStrays moves it to the main screen 10 s on, so seen in two
            // shots more than 10 s apart, it was lost.
            guard let screen = screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: x, y: y)) })
            else { counts["off every screen, waiting to move to the main one (\(name))", default: 0] += 1; return }
            // The overlay ends at the menu bar: whatever reaches above its bottom edge is cut off there.
            if y + height > screen.visibleFrame.maxY + 1 {
                odd.append("\(name) reaches \(Int(y + height - screen.visibleFrame.maxY)) pt into the menu bar")
            }
            if let wid = window {
                guard let w = snap.window(wid) else { odd.append("\(name) rides window \(wid), which is gone"); return }
                if x < w.frame.minX || x > w.frame.maxX { odd.append("\(name) stands past the end of window \(wid)") }
                if abs(y - w.frame.maxY) > 1 { odd.append("\(name) is \(Int(y - w.frame.maxY)) pt off window \(wid)'s top") }
                counts["on a window", default: 0] += 1
                return
            }
            guard let s = snap.support(x: x, y: y) else { odd.append("\(name) has nothing under it"); return }
            if y - s.top > 1 { odd.append("\(name) stands \(Int(y - s.top)) pt above what is under it") }
            counts[s.isGround ? "on the floor" : s.key == Surface.dockKey ? "on the Dock" : "on a window", default: 0] += 1
        }
        for t in decor.trees {
            let top = mainScene?.treeNodes[t.id].map { $0.calculateAccumulatedFrame().maxY } ?? 0
            note("tree", t.id, t.x, t.y, window: nil, height: max(0, top - (t.y - (mainScene?.origin.y ?? 0))))
        }
        for m in decor.snowmen { note("snowman", m.id, m.x, m.y, window: m.windowId, height: Art.snowmanSize.height) }
        for g in decor.presents { note("present", g.id, g.x, g.y, window: g.windowId, height: Art.presentSize.height) }

        let total = decor.trees.count + decor.snowmen.count + decor.presents.count
        var lines = ["audit \(decor.trees.count) trees, \(decor.snowmen.count) snowmen, \(decor.presents.count) presents: "
            + (total == 0 ? "none placed" : counts.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))
            + "; out of place: " + (odd.isEmpty ? "none" : odd.joined(separator: "; "))]
        for scene in overlays.map(\.scene) {
            for v in scene.visitors {
                let f = v.node.calculateAccumulatedFrame().offsetBy(dx: scene.origin.x, dy: scene.origin.y)
                lines.append("visitor \(type(of: v)) x \(Int(f.minX))...\(Int(f.maxX)) y \(Int(f.minY))...\(Int(f.maxY)) "
                    + "on screen \(scene.screenIndex), floor \(Int(scene.floorY + scene.origin.y)), "
                    + "menu bar from \(Int(scene.ceilingY + scene.origin.y))")
            }
        }
        return lines
    }
}
#endif
