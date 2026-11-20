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
