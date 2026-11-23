import AppKit

/// Once a day, asks GitHub for Windowsill's newest release; when it is newer than this copy, the panel
/// offers it. This is the app's only network request, and Settings turns it off.
@MainActor
final class Updates: ObservableObject {
    static let shared = Updates()
    private static let latest = URL(string: "https://api.github.com/repos/AmeenShareif/windowsill/releases/latest")!
    private static let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

    struct Release: Decodable, Equatable {
        let tagName: String
        let htmlUrl: URL
        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    @Published private(set) var newer: Release?
    private var timer: Timer?

    func start() {
        check()
        timer = .scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in Updates.shared.check() }
        }
    }

    func check() {
        guard AppState.shared.checkUpdates else { newer = nil; return }
        Task {
            var req = URLRequest(url: Self.latest, timeoutInterval: 20)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            // Offline, rate-limited or no release yet: say nothing and try again in an hour. Waiting for the daily
            // check, a Mac that woke up offline heard of an update a day late.
            guard let got = try? await URLSession.shared.data(for: req),
                  (got.1 as? HTTPURLResponse)?.statusCode == 200,
                  let r = try? decoder.decode(Release.self, from: got.0),
                  r.htmlUrl.host == "github.com" else { retryLater(); return }
            retry?.invalidate()
            newer = Self.isNewer(r.version, than: Self.current) ? r : nil
        }
    }

    private var retry: Timer?
    private func retryLater() {
        retry?.invalidate()
        retry = .scheduledTimer(withTimeInterval: 3600, repeats: false) { _ in
            Task { @MainActor in Updates.shared.check() }
        }
    }

    func open() {
        if let r = newer { NSWorkspace.shared.open(r.htmlUrl) }
    }

    /// Dotted versions compared number by number, a missing part counting as 0: "1.0.1" is newer than "1.0".
    /// Anything that is not all numbers is never newer, so a pre-release tag is not offered.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int]? {
            let raw = s.split(separator: ".", omittingEmptySubsequences: false)
            let p = raw.compactMap { Int($0) }
            return p.isEmpty || p.count != raw.count ? nil : p
        }
        guard let x = parts(a), let y = parts(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// A copy downloaded from GitHub sends its crashes to Apple, not to its developer. So the first launch after a
/// crash offers to report it: a GitHub issue opens in the browser with the crash's details filled in, for the
/// person to read and send. Nothing leaves the Mac unless they submit it there.
enum CrashReport {
    private static let seenKey = "crashesSeenUntil"
    private static let repo = "https://github.com/AmeenShareif/windowsill/issues/new"
    private static let maxBody = 6000   // the whole issue rides in the URL; browsers and GitHub cap its length
    private static let maxFrames = 20

    /// The first launch only notes where to start, so a crash from before this check existed is not offered.
    static func offerIfAny() {
        let d = UserDefaults.standard
        guard let since = d.object(forKey: seenKey) as? Date else { d.set(Date(), forKey: seenKey); return }
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                 includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let crashes = files.compactMap { u -> (url: URL, at: Date)? in
            guard u.lastPathComponent.hasPrefix("Windowsill"), u.pathExtension == "ips",
                  let t = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  t > since else { return nil }
            return (u, t)
        }
        guard let newest = crashes.map(\.at).max() else { return }
        d.set(newest, forKey: seenKey)   // asked once per crash, whatever the answer
        // Hang and other reports share the folder and the name; only crashes are offered, the newest first.
        let read = { (u: URL) in try? String(contentsOf: u, encoding: .utf8) }
        let real = crashes.sorted { $0.at > $1.at }.filter { c in read(c.url).flatMap { summary($0, file: "") } != nil }
        guard let latest = real.first, let text = read(latest.url),
              let report = summary(text, file: latest.url.lastPathComponent, count: real.count) else { return }
        let alert = NSAlert()
        alert.messageText = "Windowsill quit unexpectedly"
        alert.informativeText = "Reporting it helps get it fixed. A GitHub issue opens with the details filled in: the "
            + "Windowsill and macOS versions, the Mac model and where in the app it stopped. You read it before you "
            + "send it, and nothing is sent unless you do."
        alert.addButton(withTitle: "Report on GitHub")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn, let url = issueURL(title: report.title, body: report.body)
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// The issue's title and body from a crash report: a JSON header line, then the JSON report. Image names
    /// only, never their paths, which can hold the user's name. Nil for a report that is not a crash.
    static func summary(_ ips: String, file: String, count: Int = 1) -> (title: String, body: String)? {
        let parts = ips.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        func json(_ s: Substring?) -> [String: Any]? {
            s.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        }
        guard let head = json(parts.first), head["bug_type"] as? String == "309" else { return nil }
        let r = json(parts.count > 1 ? parts[1] : nil) ?? [:]
        let exc = r["exception"] as? [String: Any]
        let kind = [exc?["type"], exc?["signal"]].compactMap { $0 as? String }.joined(separator: " ")
        var lines = ["Windowsill \(head["app_version"] as? String ?? "?") on \(head["os_version"] as? String ?? "macOS ?")"
                     + ((r["modelCode"] as? String).map { ", \($0)" } ?? ""),
                     "Crash: \(kind.isEmpty ? "unknown" : kind)"]
        if count > 1 { lines.append("Crashes since the last report: \(count)") }
        let asi = r["asi"] as? [String: [String]] ?? [:]
        for lib in asi.keys.sorted() { lines += asi[lib, default: []].map { "\(lib): \($0)" } }
        let images = (r["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "?" }
        let threads = r["threads"] as? [[String: Any]] ?? []
        let i = r["faultingThread"] as? Int ?? 0
        let frames = i < threads.count ? threads[i]["frames"] as? [[String: Any]] ?? [] : []
        var stopped: String?
        for (k, f) in frames.prefix(maxFrames).enumerated() {
            let ix = f["imageIndex"] as? Int ?? -1
            let image = ix >= 0 && ix < images.count ? images[ix] : "?"
            let symbol = f["symbol"] as? String ?? "offset \(f["imageOffset"] as? Int ?? 0)"
            if image == "Windowsill", stopped == nil { stopped = symbol }
            lines.append("\(k) \(image) \(symbol)")
        }
        var body = "What went wrong, filled in by Windowsill:\n\n```\n" + lines.joined(separator: "\n") + "\n```\n\n"
            + "The full report is on your Mac at ~/Library/Logs/DiagnosticReports/\(file) if you'd like to attach it.\n\n"
            + "What were you doing when it happened?\n"
        if body.count > maxBody { body = String(body.prefix(maxBody)) + "\n```\n" }
        return ("Crash: \(kind.isEmpty ? "unknown" : kind)" + (stopped.map { " in \($0)" } ?? ""), body)
    }

    /// A new-issue page with the title and body filled in. URLComponents leaves "+" alone, which GitHub would
    /// read as a space.
    static func issueURL(title: String, body: String) -> URL? {
        var c = URLComponents(string: repo)
        c?.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "body", value: body)]
        c?.percentEncodedQuery = c?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c?.url
    }
}
