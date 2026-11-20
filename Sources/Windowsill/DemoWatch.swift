import Foundation
import QuartzCore

#if DEMO
/// The longest the main thread kept a ping from another thread waiting since the last read. A long frame gap
/// with a short wait here is macOS not drawing (the display link starved), not this app holding its thread.
///
/// A second thread does nothing but sleep 5 ms at a time. When it also overslept by about as long as the main
/// thread kept the ping waiting, nothing in this app ran at all: the machine, not the main thread, stopped.
/// A wait past a quarter second also takes a one-second stack sample of the app, `<mode>-stall-<n>.txt` beside
/// the shots, so a stall in a video comes with what the main thread was doing in it.
final class MainWatch {
    static let shared = MainWatch()
    private let lock = NSLock()
    private var worst: CFTimeInterval = 0
    private var overslept: CFTimeInterval = 0
    private var samples: [String] = []   // taken since the last read
    private var taken = 0
    private var stallDir: (url: URL, mode: String)?
    private static let stallAfter: TimeInterval = 0.25
    private static let maxSamples = 6

    private init() {
        Thread.detachNewThread { [unowned self] in
            while true {
                let sent = CACurrentMediaTime()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + Self.stallAfter) == .timedOut {
                    self.sampleStall()
                    answered.wait()
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

    /// Where stall samples go, named after the demo mode.
    func sampleInto(_ dir: URL?, mode: String) {
        lock.lock(); stallDir = dir.map { ($0, mode) }; lock.unlock()
    }

    /// `sudo sample` for a second, in the background: only root may look into an app signed with the hardened
    /// runtime, and the CI runner's admin needs no password (`-n` gives up rather than ask anywhere else).
    private func sampleStall() {
        lock.lock()
        guard let dir = stallDir, taken < Self.maxSamples else { lock.unlock(); return }
        taken += 1
        let name = "\(dir.mode)-stall-\(taken).txt"
        samples.append(name)
        lock.unlock()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/sample", "\(getpid())", "1", "1", "-mayDie",
                       "-file", dir.url.appendingPathComponent(name).path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// The worst wait since the last read, how late the sleeping thread woke, and any stall samples taken;
    /// then starts over.
    func read() -> String {
        lock.lock()
        defer { worst = 0; overslept = 0; samples = []; lock.unlock() }
        var s = String(format: "%.1f ms (a thread sleeping 5 ms at a time woke up to %.1f ms late", worst * 1000,
                       overslept * 1000)
        if !samples.isEmpty { s += "; sampled in " + samples.joined(separator: ", ") }
        return s + ")"
    }
}
#endif
