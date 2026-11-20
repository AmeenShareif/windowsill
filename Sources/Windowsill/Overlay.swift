import AppKit
import SpriteKit

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
    /// Told when the panel is covered or uncovered. Removed on close: every display change builds new
    /// overlays, and the old ones' observers stayed registered for good.
    private var occlusion: NSObjectProtocol?

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

    func onOcclusionChange(_ run: @escaping () -> Void) {
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                           object: panel, queue: .main) { _ in run() }
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
        if let occlusion { NotificationCenter.default.removeObserver(occlusion) }
        occlusion = nil
        view.presentScene(nil)
        panel.orderOut(nil)
        panel.close()
    }
}
