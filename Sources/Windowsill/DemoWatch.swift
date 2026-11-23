import AppKit
import Darwin
import Foundation
import QuartzCore
import SwiftUI

#if DEMO
/// The longest the main thread kept a ping from another thread waiting since the last read. A long frame gap
/// with a short wait here is macOS not drawing (the display link starved), not this app holding its thread.
///
/// A second thread does nothing but sleep 5 ms at a time. When it also overslept by about as long as the main
/// thread kept the ping waiting, nothing in this app ran at all: the machine, not the main thread, stopped.
/// A wait past 0.12 s also records the main thread's stack every tenth of a second until it answers,
/// as `<mode>-stall-<n>.txt` beside the shots, so a stall in a video comes with what the main thread was doing
/// in it. (`sudo sample` started from here attached after the stall it was for had ended.)
final class MainWatch {
    static let shared = MainWatch()
    private let lock = NSLock()
    private var worst: CFTimeInterval = 0
    private var overslept: CFTimeInterval = 0
    private var stalls: [String] = []   // written since the last read
    private var taken = 0
    private var stallDir: (url: URL, mode: String)?
    private static let stallAfter: TimeInterval = 0.12   // under the 0.2 s window shake on macOS 27, to name it
    private static let maxStalls = 12
    private static let maxLooks = 8
    private static let maxFrames = 64
    /// Room for one stack, set aside before the main thread is held: holding it, nothing may allocate.
    private let pcs = UnsafeMutablePointer<UInt>.allocate(capacity: MainWatch.maxFrames)
    private let stackLock = NSLock()
    /// The main thread and its stack's ends, taken here: the demo's start, on the main thread, makes this.
    private let mainPort: mach_port_t
    private let mainBounds: (bottom: UInt, top: UInt)

    private init() {
        let me = pthread_self()
        mainPort = Thread.isMainThread ? pthread_mach_thread_np(me) : 0
        let top = UInt(bitPattern: pthread_get_stackaddr_np(me))
        mainBounds = (top - UInt(pthread_get_stacksize_np(me)), top)
        Thread.detachNewThread { [unowned self] in
            while true {
                let sent = CACurrentMediaTime()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + Self.stallAfter) == .timedOut {
                    var looks: [(at: CFTimeInterval, stack: [UInt])] = []
                    repeat {
                        looks.append((CACurrentMediaTime() - sent, self.mainStack()))
                    } while looks.count < Self.maxLooks && answered.wait(timeout: .now() + 0.1) == .timedOut
                    if looks.count == Self.maxLooks { answered.wait() }
                    self.write(looks, waited: CACurrentMediaTime() - sent, from: sent - FrameCost.t0)
                }
                let waited = CACurrentMediaTime() - sent
                self.lock.lock(); self.worst = max(self.worst, waited); self.lock.unlock()
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        Thread.detachNewThread { [unowned self] in
            let nap = 0.005
            while true {
                let t = CACurrentMediaTime()
                Thread.sleep(forTimeInterval: nap)
                let late = CACurrentMediaTime() - t - nap
                self.lock.lock(); self.overslept = max(self.overslept, late); self.lock.unlock()
            }
        }
    }

    /// Where stall stacks go, named after the demo mode.
    func sampleInto(_ dir: URL?, mode: String) {
        lock.lock(); stallDir = dir.map { ($0, mode) }; lock.unlock()
    }

    /// Samples the main thread's stack every 2 ms for `seconds`, then writes where its time went beside the shots,
    /// as `<mode>-<name>-profile.txt`: a slow frame that stays under the stall line leaves no stack otherwise.
    func profile(_ name: String, for seconds: CFTimeInterval) {
        Thread.detachNewThread { [unowned self] in
            var samples: [[UInt]] = []
            let start = CACurrentMediaTime(), end = start + seconds
            while CACurrentMediaTime() < end {
                samples.append(self.mainStack())
                Thread.sleep(forTimeInterval: 0.002)
            }
            self.writeProfile(samples, name: name, every: (CACurrentMediaTime() - start) / Double(max(samples.count, 1)),
                         from: start - FrameCost.t0)
        }
    }

    private func writeProfile(_ samples: [[UInt]], name: String, every: CFTimeInterval, from: CFTimeInterval) {
        lock.lock(); let dir = stallDir; lock.unlock()
        guard let dir else { return }
        var names: [UInt: String] = [:]
        func symbol(_ pc: UInt) -> String {
            if let s = names[pc] { return s }
            let s = Self.symbol(pc).replacingOccurrences(of: #" \+ \d+$"#, with: "", options: .regularExpression)
            names[pc] = s
            return s
        }
        // A sample waiting in the run loop for the next event is idle; every other one is time spent.
        let busy = samples.map { $0.map(symbol) }.filter { !$0.contains { $0.contains("__CFRunLoopServiceMachPort") } }
        var inclusive: [String: Int] = [:], leaf: [String: Int] = [:]
        for s in busy {
            Set(s).forEach { inclusive[$0, default: 0] += 1 }
            if let top = s.first { leaf[top, default: 0] += 1 }
        }
        func table(_ d: [String: Int], _ n: Int) -> String {
            d.sorted { $0.value > $1.value }.prefix(n).map { String(format: "%5.1f ms  ", Double($0.value) * every * 1000)
                + String($0.key.prefix(190)) }.joined(separator: "\n")
        }
        let text = String(format: "%ld samples %.1f ms apart from %.2f s; %ld busy (%.0f ms)\n\nInclusive:\n",
                          samples.count, every * 1000, from, busy.count, Double(busy.count) * every * 1000)
            + table(inclusive, 60) + "\n\nInnermost frame:\n" + table(leaf, 25) + "\n"
        try? text.write(to: dir.url.appendingPathComponent("\(dir.mode)-\(name)-profile.txt"), atomically: true, encoding: .utf8)
    }

    /// The main thread's return addresses, read by walking its frame pointers while it is held still.
    private func mainStack() -> [UInt] {
        stackLock.lock(); defer { stackLock.unlock() }   // one buffer, shared by the stall watch and a profile
        #if arch(arm64)
        let port = mainPort, (bottom, top) = mainBounds
        guard port != 0 else { return [] }
        let pcs = self.pcs, cap = Self.maxFrames
        let addressBits: UInt = 0x0000_7FFF_FFFF_FFFF   // above them, pointer authentication bits
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        guard thread_suspend(port) == KERN_SUCCESS else { return [] }
        let got = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(port, ARM_THREAD_STATE64, $0, &count)
            }
        }
        var n = 0
        if got == KERN_SUCCESS {
            pcs[0] = UInt(state.__pc) & addressBits
            pcs[1] = UInt(state.__lr) & addressBits
            n = 2
            var fp = UInt(state.__fp)
            while n < cap, fp & 7 == 0, fp >= bottom, fp <= top - 16, let frame = UnsafePointer<UInt>(bitPattern: fp) {
                let ret = frame[1] & addressBits
                if ret == 0 { break }
                pcs[n] = ret
                n += 1
                if frame[0] <= fp { break }
                fp = frame[0]
            }
        }
        thread_resume(port)
        return Array(UnsafeBufferPointer(start: pcs, count: n))
        #else
        return []
        #endif
    }

    private func write(_ looks: [(at: CFTimeInterval, stack: [UInt])], waited: CFTimeInterval, from: CFTimeInterval) {
        lock.lock()
        guard let dir = stallDir, taken < Self.maxStalls else { lock.unlock(); return }
        taken += 1
        let name = "\(dir.mode)-stall-\(taken).txt"
        stalls.append(name)
        lock.unlock()
        // From: the demo's clock, as FrameCost's slow frames give it, so a stall can be put beside its frames.
        var text = String(format: "The main thread kept a ping waiting %.0f ms from %.2f s. Its stack, looked at every 0.1 s:\n",
                          waited * 1000, from)
        for look in looks {
            text += String(format: "\nat %.0f ms\n", look.at * 1000)
            text += look.stack.map { "  " + Self.symbol($0) }.joined(separator: "\n") + "\n"
        }
        try? text.write(to: dir.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    static func symbol(_ pc: UInt) -> String {
        var info = Dl_info()
        guard let p = UnsafeRawPointer(bitPattern: pc), dladdr(p, &info) != 0 else { return String(format: "0x%lx", pc) }
        let lib = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        guard let sname = info.dli_sname else { return "\(lib)  0x" + String(pc, radix: 16) }
        var name = String(cString: sname)
        if let readable = swiftDemangle(sname, strlen(sname), nil, nil, 0) {
            name = String(cString: readable)
            free(readable)
        }
        return "\(lib)  \(name) + \(pc - UInt(bitPattern: info.dli_saddr))"
    }

    /// The worst wait since the last read, how late the sleeping thread woke, and any stalls written;
    /// then starts over.
    func read() -> String {
        lock.lock()
        defer { worst = 0; overslept = 0; stalls = []; lock.unlock() }
        var s = String(format: "%.1f ms (a thread sleeping 5 ms at a time woke up to %.1f ms late", worst * 1000,
                       overslept * 1000)
        if !stalls.isEmpty { s += "; main thread stacks in " + stalls.joined(separator: ", ") }
        return s + ")"
    }
}

/// CPU time the scene's thread spent per frame: inside the scene's update, and from one frame's start to the
/// next (SpriteKit's drawing, SwiftUI, everything else on that thread). Thread CPU time stands still while the
/// thread waits or the machine is paused, so unlike a frame gap it measures this app's own work, against the
/// 16.7 ms a frame has at 60 Hz. The frame gaps of identical code swung 6x between CI Macs (runs 78, 79).
final class FrameCost {
    /// When the demo's script started, so an over-budget frame can be matched to the step that ran then.
    static var t0: CFTimeInterval = 0
    private var update: [UInt64] = []
    private var frame: [UInt64] = []
    private var over: [String] = []
    private var last: UInt64 = 0
    private var lastAt: CFTimeInterval = 0

    /// As the scene's update starts; returns what `end` takes.
    func start() -> UInt64 {
        let now = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        if last > 0 {
            frame.append(now - last)
            if now - last > 16_700_000, over.count < 8 {
                over.append(String(format: "%.0f ms at %.2f s (update %.1f)", Double(now - last) / 1e6, lastAt - Self.t0,
                                   Double(update.last ?? 0) / 1e6))
            }
        }
        last = now
        lastAt = CACurrentMediaTime()
        return now
    }

    func end(_ start: UInt64) { update.append(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) }

    /// The frame a shot's own bookkeeping ran in is the demo's cost, not the app's: it is left out.
    func skip() { last = 0 }

    /// Since the last read, then starts over.
    func read() -> String {
        defer { update = []; frame = []; over = [] }
        func ms(_ a: [UInt64]) -> String {
            guard !a.isEmpty else { return "none" }
            let s = a.sorted()
            let at = { (q: Double) in Double(s[Int(q * Double(s.count - 1))]) / 1e6 }
            return String(format: "median %.2f p99 %.2f max %.2f ms", at(0.5), at(0.99), at(1))
        }
        return "cpu per frame: update \(ms(update)); whole frame \(ms(frame)) over \(frame.count) frames"
            + (over.isEmpty ? "" : "\nover 16.7 ms: " + over.joined(separator: ", "))
    }
}

/// What the snowflake did, with times, for the panel demo's notes: the button's action, macOS 27's expanded
/// interface session beginning and ending, and a click on it closing the panel (MenuPanel.log).
final class SnowflakeLog {
    static let shared = SnowflakeLog()
    private var log: [String] = []
    private let t0 = CACurrentMediaTime()

    func note(_ s: String) {
        let p = MenuPanel.shared
        log.append(String(format: "%.0f ms ", (CACurrentMediaTime() - t0) * 1000)
                   + "\(s) (panel \(p.isOpen ? "open" : "shut")\(p.panel.isKeyWindow ? ", key" : ""))")
    }

    /// The log since the last take.
    func take() -> String { defer { log = [] }; return log.joined(separator: "; ") }
}

/// Which of the panel's views ran their body since the last shot, and when, for the panel demo's notes: what an
/// open, a shut or a tab click makes SwiftUI redo.
enum BodyLog {
    private static var runs: [String: [CFTimeInterval]] = [:]
    static func ran(_ name: String) { runs[name, default: []].append(CACurrentMediaTime()) }
    static func take() -> String? {
        defer { runs = [:] }
        guard !runs.isEmpty else { return nil }
        return "bodies run: " + runs.sorted { $0.key < $1.key }
            .map { "\($0.key) at " + $0.value.prefix(6).map { String(format: "%.2f", $0) }.joined(separator: " ") }
            .joined(separator: "; ")
    }
}

func bodyRan(_ name: String) { BodyLog.ran(name) }

/// The panel's hosting view in the demo build: every layout over 8 ms, how long, and the stacks that asked for it
/// since the one before. Open, shut and a tab click each cost one full SwiftUI update while no body of ours runs
/// (run 45253353077), so what asks is the question.
final class WatchedHost<Content: View>: NSHostingView<Content> {
    override var needsLayout: Bool {
        get { super.needsLayout }
        set {
            if newValue, HostLog.asks.count < 3 {
                HostLog.asks.append((CACurrentMediaTime(), Thread.callStackReturnAddresses.dropFirst(2).prefix(22).map(\.uintValue)))
            }
            super.needsLayout = newValue
        }
    }

    override func layout() {
        let t = CACurrentMediaTime()
        super.layout()
        let ms = (CACurrentMediaTime() - t) * 1000
        if ms > 8, HostLog.slow.count < 3 { HostLog.slow.append((t, ms, HostLog.asks)) }
        HostLog.asks = []
    }
}

/// Raw until a shot asks: named then, while the shot's frame is skipped, not inside the frame being measured.
enum HostLog {
    static var asks: [(CFTimeInterval, [UInt])] = []
    static var slow: [(at: CFTimeInterval, ms: Double, asks: [(CFTimeInterval, [UInt])])] = []
    static func take() -> [String] {
        defer { slow = [] }
        return slow.flatMap { s in
            [String(format: "host layout %.0f ms at %.2f s", s.ms, s.at) + (s.asks.isEmpty ? ", not asked through needsLayout" : "")]
                + s.asks.map { String(format: "  asked at %.2f s by: ", $0.0) + $0.1.map(MainWatch.symbol).joined(separator: " < ") }
        }
    }
}

/// A bare panel, for this Mac's own floor: borderless glass like the menu bar's, holding one switch, one slider
/// and one button as SwiftUI's controls, or the real panel's view, without MenuPanel's fading, sizing and
/// snowflake. The whole view cost 58-101 ms to open, each tab alone 20-39, the header 9 (run 45244728361); made
/// key it cost 46-82 ms, not made key 5-8, and pinning appearsActive and controlActiveState changed nothing (run
/// 45248910475). So each kind here is the whole view, twice for the noise: made key as before, made key with a
/// first responder of its own (MenuPanel.KeyHolder, as the real panel now has), and not made key.
enum PanelFloor {
    private final class Key: NSPanel { override var canBecomeKey: Bool { true } }
    static let kinds = ["swiftui"] + ["whole", "whole-holder", "whole-nokey"].flatMap { [$0, $0] }

    static func make(_ kind: String) -> NSPanel {
        let swiftUI = kind == "swiftui"
        let p = Key(contentRect: CGRect(x: 360, y: 300, width: 300, height: 150), styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = AboveTheWeather.level
        p.isReleasedWhenClosed = false
        let host = swiftUI ? NSHostingView(rootView: AnyView(VStack(alignment: .leading) {
            Toggle("Snow", isOn: .constant(true)).toggleStyle(.switch)
            Slider(value: .constant(0.5))
            Button("Quit") {}
        }.padding())) : NSHostingView(rootView: AnyView(PanelView()))
        let size = host.fittingSize
        // As the real panel holds it: in a plain view, beside its own first responder when the kind has one.
        let page = NSView(frame: CGRect(origin: .zero, size: size))
        host.frame = page.bounds
        host.autoresizingMask = [.width, .height]
        page.addSubview(host)
        if kind.contains("holder") {
            let h = MenuPanel.KeyHolder()
            h.nextKeyView = host
            page.addSubview(h)
            p.initialFirstResponder = h
        }
        let glass = NSGlassEffectView()
        glass.cornerRadius = 13
        glass.contentView = page
        p.contentView = glass
        p.setContentSize(size)
        return p
    }

    /// The demo's steps from `t`: each panel opened and shut once, then again with its frames read, a shot after
    /// each of those. The first time is left out, as the real panel's is drawn at launch.
    static func steps(from t: TimeInterval) -> [(TimeInterval, String?, () -> Void)] {
        var out: [(TimeInterval, String?, () -> Void)] = []
        for (k, kind) in kinds.enumerated() {
            let s = t + Double(k) * 2.4, key = !kind.contains("nokey")
            var p: NSPanel?
            let show: () -> Void = { if key { p?.makeKeyAndOrderFront(nil) } else { p?.orderFront(nil) } }
            out += [(s, nil, { p = make(kind); show() }),
                    (s + 0.4, nil, { p?.orderOut(nil) }),
                    (s + 0.8, nil, { _ = Engine.shared.mainScene?.cost.read(); show() }),
                    (s + 1.4, "floor-\(k)-\(kind)-open", {}),
                    (s + 1.5, nil, { p?.orderOut(nil) }),
                    (s + 2.1, "floor-\(k)-\(kind)-shut", {})]
        }
        return out
    }
}

/// Where clicks on the open panel would land. AppKit hands a click to whatever its content view's hitTest finds,
/// and a hidden tab's controls stay in the window while Warmth draws it (PanelView), over or under the shown
/// tab's: a point that finds one of them is a click the person sees go nowhere, or into a tab they cannot see.
enum HitProbe {
    static func unseen(in w: NSWindow?) -> String {
        guard let w, let root = w.contentView, let top = root.superview else { return "hit test: no panel" }
        var n = 0
        var bad: [String] = []
        for x in stride(from: CGFloat(4), to: root.bounds.width, by: 8) {
            for y in stride(from: CGFloat(4), to: root.bounds.height, by: 8) {
                n += 1
                guard let v = root.hitTest(root.convert(CGPoint(x: x, y: y), to: top)) else { continue }
                var seen: Float = 1
                var l = v.layer
                while let layer = l { seen *= layer.isHidden ? 0 : layer.opacity; l = layer.superlayer }
                if seen < 0.5 { bad.append("\(type(of: v)) at \(Int(x)),\(Int(y))") }
            }
        }
        return "hit test: \(bad.count) of \(n) points on the panel land on a control nobody sees"
            + (bad.isEmpty ? "" : " (\(bad.prefix(3).joined(separator: ", ")))")
    }
}

/// The Swift runtime's own demangler, so a stall's stack reads `Engine.tick()` rather than `$s10Windowsill...`.
@_silgen_name("swift_demangle")
private func swiftDemangle(_ mangled: UnsafePointer<CChar>?, _ length: Int, _ output: UnsafeMutablePointer<CChar>?,
                           _ size: UnsafeMutablePointer<Int>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?
#endif
