import AppKit
import Darwin
import Foundation
import QuartzCore

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
                    self.write(looks, waited: CACurrentMediaTime() - sent)
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

    /// The main thread's return addresses, read by walking its frame pointers while it is held still.
    private func mainStack() -> [UInt] {
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

    private func write(_ looks: [(at: CFTimeInterval, stack: [UInt])], waited: CFTimeInterval) {
        lock.lock()
        guard let dir = stallDir, taken < Self.maxStalls else { lock.unlock(); return }
        taken += 1
        let name = "\(dir.mode)-stall-\(taken).txt"
        stalls.append(name)
        lock.unlock()
        var text = String(format: "The main thread kept a ping waiting %.0f ms. Its stack, looked at every 0.1 s:\n",
                          waited * 1000)
        for look in looks {
            text += String(format: "\nat %.0f ms\n", look.at * 1000)
            text += look.stack.map { "  " + Self.symbol($0) }.joined(separator: "\n") + "\n"
        }
        try? text.write(to: dir.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private static func symbol(_ pc: UInt) -> String {
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

/// What macOS does when the snowflake is clicked with the real mouse: the button's action, and on macOS 27 the
/// calls to a status item's expanded interface delegate, which ends the highlight trouble there (FB23330269)
/// if the menu bar draws its capsule through a session. The 26 SDK this app builds with has no such API, so
/// the delegate is found and set at run time, and any of its methods not written here is logged by name.
final class SessionProbe: NSObject {
    static let shared = SessionProbe()
    private var log: [String] = []
    private let t0 = CACurrentMediaTime()

    func note(_ s: String) {
        let p = MenuPanel.shared
        log.append(String(format: "%.0f ms ", (CACurrentMediaTime() - t0) * 1000)
                   + "\(s) (panel \(p.isOpen ? "open" : "shut")\(p.panel.isKeyWindow ? ", key" : ""))")
    }

    /// The log since the last take.
    func take() -> String { defer { log = [] }; return log.joined(separator: "; ") }

    /// The snowflake's clicks come here first, to be logged, then go on to the panel as before.
    func logAction(of b: NSStatusBarButton) {
        b.target = self
        b.action = #selector(clicked)
    }

    @objc private func clicked() {
        note("button action")
        MenuPanel.shared.toggle()
    }

    /// Becomes the item's expanded interface delegate where macOS has one. Returns what it found.
    func becomeDelegate(of item: NSStatusItem) -> String {
        guard let proto = objc_getProtocol("NSStatusItemExpandedInterfaceDelegate") else {
            return "macOS has no expanded interface delegate"
        }
        var found: [String] = []
        for required in [true, false] {
            var n: UInt32 = 0
            guard let list = protocol_copyMethodDescriptionList(proto, required, true, &n) else { continue }
            defer { free(list) }
            for d in UnsafeBufferPointer(start: list, count: Int(n)) {
                guard let sel = d.name else { continue }
                let types = d.types.map { String(cString: $0) } ?? "?"
                found.append(NSStringFromSelector(sel) + " " + types + (required ? " required" : ""))
                if !responds(to: sel), types.hasPrefix("v") { logCalls(of: sel, types) }
            }
        }
        class_addProtocol(SessionProbe.self, proto)
        let api = "protocol " + found.joined(separator: ", ") + "; status item "
            + Self.methods(of: NSStatusItem.self, with: "xpanded").joined(separator: ", ")
        let setter = NSSelectorFromString("setExpandedInterfaceDelegate:")
        guard item.responds(to: setter) else { return "NO DELEGATE SETTER; " + api }
        _ = item.perform(setter, with: self)
        return "delegate set; " + api
    }

    /// A delegate method not written below: logged by name. Void ones only, so nothing is returned unasked.
    private func logCalls(of sel: Selector, _ types: String) {
        let name = NSStringFromSelector(sel)
        let block: @convention(block) (AnyObject, UnsafeRawPointer?, UnsafeRawPointer?) -> Void = { _, _, _ in
            SessionProbe.shared.note(name)
        }
        class_addMethod(SessionProbe.self, sel, imp_implementationWithBlock(block), types)
    }

    @objc(statusItem:didBeginExpandedInterfaceSession:)
    func began(_ item: NSStatusItem, session: AnyObject) {
        let cls: AnyClass = object_getClass(session) ?? NSObject.self
        note("session began: \(cls) with " + Self.methods(of: cls, with: nil).joined(separator: " "))
        // Should the action not come with the session, the panel is opened from it, so the shot shows both.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard !MenuPanel.shared.isOpen else { return }
            self.note("no action came, so the panel was opened from the session")
            MenuPanel.shared.open()
        }
    }

    @objc(statusItemDidEndExpandedInterfaceSession:animated:)
    func ended(_ item: NSStatusItem, animated: Bool) { note("session ended, animated \(animated)") }

    private static func methods(of cls: AnyClass, with word: String?) -> [String] {
        var n: UInt32 = 0
        guard let list = class_copyMethodList(cls, &n) else { return [] }
        defer { free(list) }
        return UnsafeBufferPointer(start: list, count: Int(n)).map { NSStringFromSelector(method_getName($0)) }
            .filter { s in word.map { s.contains($0) } ?? !s.hasPrefix("_") }.prefix(24).map { $0 }
    }
}

/// The Swift runtime's own demangler, so a stall's stack reads `Engine.tick()` rather than `$s10Windowsill...`.
@_silgen_name("swift_demangle")
private func swiftDemangle(_ mangled: UnsafePointer<CChar>?, _ length: Int, _ output: UnsafeMutablePointer<CChar>?,
                           _ size: UnsafeMutablePointer<Int>?, _ flags: UInt32) -> UnsafeMutablePointer<CChar>?
#endif
