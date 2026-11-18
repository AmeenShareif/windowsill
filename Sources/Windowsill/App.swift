import AppKit
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
            PanelView()
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var demo: DemoRun?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        Engine.shared.start()
        if let d = Demo.parse(CommandLine.arguments) {
            demo = DemoRun(d)
            demo?.start()
        }
    }
}
