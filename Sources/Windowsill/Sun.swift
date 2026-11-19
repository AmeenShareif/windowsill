import AppKit
import CoreLocation

/// Where the sun is for this Mac, from its clock and a rough location, so the paintings and the light the
/// weather is drawn in follow the real day: brighter at noon, warm at sunrise and sunset, blue-grey at night.
/// The location is asked for once; declined, it is estimated from the time zone. It is kept to a tenth of a
/// degree (about 10 km) and never leaves the Mac.
final class Sun: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Sun()

    struct Place: Equatable { var lat: Double; var lon: Double; var estimated: Bool }

    @Published private(set) var place: Place
    /// What time it is for the sun; the demo runs a faster clock in a fixed place, the same on every Mac.
    private(set) var clock: () -> Date = Date.init
    private lazy var manager = CLLocationManager()
    private static let key = "sunPlace"

    override init() {
        let demo = CommandLine.arguments.contains("--demo")
        place = (demo ? nil : Self.saved()) ?? Self.estimate(TimeZone.current)
        super.init()
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            guard let self, !demo else { return }
            NSTimeZone.resetSystemTimeZone()
            if self.place.estimated { self.place = Self.estimate(TimeZone.current) }
            self.locate()
            WallpaperManager.shared.apply()
        }
    }

    func pin(_ p: Place, clock: @escaping () -> Date) {
        place = p
        self.clock = clock
    }

    // MARK: - Location

    /// Asks macOS once for the Mac's rough location (it shows its own prompt the first time), then refreshes it
    /// at each launch and time zone change, since a laptop travels.
    func locate() {
        let m = manager
        m.delegate = self
        m.desiredAccuracy = kCLLocationAccuracyKilometer
        if m.authorizationStatus == .notDetermined { m.requestWhenInUseAuthorization() } else { locationManagerDidChangeAuthorization(m) }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .notDetermined:
            break
        case .denied, .restricted:
            // Taken back: forget where the Mac was and go by the time zone.
            UserDefaults.standard.removeObject(forKey: Self.key)
            if !place.estimated { place = Self.estimate(TimeZone.current) }
        default:
            m.requestLocation()
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate, CLLocationCoordinate2DIsValid(c) else { return }
        let p = Place(lat: (c.latitude * 10).rounded() / 10, lon: (c.longitude * 10).rounded() / 10, estimated: false)
        UserDefaults.standard.set([p.lat, p.lon], forKey: Self.key)
        guard p != place else { return }
        place = p
        WallpaperManager.shared.apply()
    }

    /// No fix (no Wi-Fi nearby, Location Services off): the last place, or the time zone's estimate, stands.
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        NSLog("Windowsill: no location fix, keeping %@: %@", place.estimated ? "the time zone's estimate" : "the last place",
              error.localizedDescription)
    }

    private static func saved() -> Place? {
        guard let a = UserDefaults.standard.array(forKey: key) as? [Double], a.count == 2 else { return nil }
        return Place(lat: a[0], lon: a[1], estimated: false)
    }

    /// The time zone's own city, from the system's zone table, or failing that its offset from UTC at 40 degrees north.
    static func estimate(_ zone: TimeZone) -> Place {
        if let table = try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8) {
            for line in table.split(separator: "\n") where !line.hasPrefix("#") {
                let f = line.split(separator: "\t")
                if f.count >= 3, f[2] == zone.identifier, let p = coordinates(f[1]) {
                    return Place(lat: p.lat, lon: p.lon, estimated: true)
                }
            }
        }
        let standard = Double(zone.secondsFromGMT()) - zone.daylightSavingTimeOffset()
        return Place(lat: 40, lon: standard / 240, estimated: true)
    }

    /// zone.tab's ISO 6709 coordinates: `+4043-07400` or `+404251-0740023`.
    static func coordinates(_ s: Substring) -> (lat: Double, lon: Double)? {
        guard let cut = s.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        func angle(_ part: Substring, degreeDigits n: Int) -> Double? {
            let sign: Double = part.first == "-" ? -1 : 1
            let d = Array(part.dropFirst())
            guard d.count >= n + 2, d.allSatisfy(\.isNumber) else { return nil }
            func number(_ a: Int, _ b: Int) -> Double { Double(String(d[min(a, d.count)..<min(b, d.count)])) ?? 0 }
            return sign * (number(0, n) + number(n, n + 2) / 60 + number(n + 2, n + 4) / 3600)
        }
        guard let lat = angle(s[..<cut], degreeDigits: 2), let lon = angle(s[cut...], degreeDigits: 3) else { return nil }
        return (lat, lon)
    }

    // MARK: - The sun's place in the sky

    private static let rad = Double.pi / 180

    /// The sun's declination and right ascension, and the sidereal time at Greenwich, in degrees: the Astronomical
    /// Almanac's low-precision formulas, good to about a hundredth of a degree for centuries either side of 2000.
    private static func solar(_ date: Date) -> (dec: Double, ra: Double, gmst: Double) {
        let n = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0
        let l = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
        let g = (357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360) * rad
        let lambda = (l + 1.915 * sin(g) + 0.020 * sin(2 * g)) * rad
        let eps = (23.439 - 0.0000004 * n) * rad
        let ra = atan2(cos(eps) * sin(lambda), cos(lambda)) / rad
        let dec = asin(sin(eps) * sin(lambda)) / rad
        let gmst = (280.46061837 + 360.98564736629 * n).truncatingRemainder(dividingBy: 360)
        return (dec, ra, gmst)
    }

    /// How high the sun stands, in degrees, and its hour angle: negative before solar noon, positive after.
    static func position(at date: Date, lat: Double, lon: Double) -> (elevation: Double, hourAngle: Double) {
        let s = solar(date)
        var h = (s.gmst + lon - s.ra).truncatingRemainder(dividingBy: 360)
        if h > 180 { h -= 360 } else if h < -180 { h += 360 }
        let e = sin(lat * rad) * sin(s.dec * rad) + cos(lat * rad) * cos(s.dec * rad) * cos(h * rad)
        return (asin(max(-1, min(1, e))) / rad, h)
    }

    /// Sunrise and sunset on the day around `noon` (the upper limb on the horizon, refraction allowed for),
    /// or nil on a day the sun never rises or never sets.
    static func riseSet(around noon: Date, lat: Double, lon: Double) -> (rise: Date, set: Date)? {
        var transit = noon
        for _ in 0..<2 { transit -= position(at: transit, lat: lat, lon: lon).hourAngle / 360 * 86400 }
        let dec = solar(transit).dec * rad
        let c = (sin(-0.833 * rad) - sin(lat * rad) * sin(dec)) / (cos(lat * rad) * cos(dec))
        guard abs(c) <= 1 else { return nil }
        let half = acos(c) / rad / 360 * 86400
        return (transit - half, transit + half)
    }

    // MARK: - What the app shows

    private var now: (elevation: Double, hourAngle: Double) { Self.position(at: clock(), lat: place.lat, lon: place.lon) }

    /// The real time of day, from how high the sun is and whether it is still climbing.
    var timeOfDay: TimeOfDay { let p = now; return TimeOfDay.of(elevation: p.elevation, hourAngle: p.hourAngle) }

    /// How high the sun stands for the light the weather is drawn in: the real sun, or the light picked in Wallpaper.
    var lightElevation: Double { AppState.shared.dayNight ? now.elevation : AppState.shared.fixedTime.elevation }

    /// Today's sunrise and sunset here, in words.
    var today: String {
        let date = clock()
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        let whence = place.estimated ? " (estimated from your time zone)" : ""
        guard let rs = Self.riseSet(around: noon, lat: place.lat, lon: place.lon) else {
            let up = Self.position(at: noon, lat: place.lat, lon: place.lon).elevation > 0
            return (up ? "The sun does not set here today" : "The sun does not rise here today") + whence + "."
        }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return "Sunrise \(f.string(from: rs.rise)), sunset \(f.string(from: rs.set))\(whence)."
    }

    /// The light the weather is drawn in with the sun `e` degrees up: white by day, warm as it nears the horizon,
    /// lavender in twilight, a dim blue-grey at night. Multiplied into each flake, leaf, drop and pile.
    static func tint(elevation e: Double) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let keys: [(e: Double, r: Double, g: Double, b: Double)] = [
            (-12, 0.70, 0.76, 0.94), (-6, 0.80, 0.78, 0.95), (0, 1, 0.86, 0.74), (10, 1, 1, 1)]
        guard e > keys[0].e else { return (0.70, 0.76, 0.94) }
        guard let i = keys.firstIndex(where: { $0.e >= e }) else { return (1, 1, 1) }
        let a = keys[i - 1], b = keys[i], k = (e - a.e) / (b.e - a.e)
        return (CGFloat(a.r + (b.r - a.r) * k), CGFloat(a.g + (b.g - a.g) * k), CGFloat(a.b + (b.b - a.b) * k))
    }
}

extension TimeOfDay {
    /// From the sun's height and hour angle: twilight is the sun up to 6 degrees under the horizon, sunrise and
    /// sunset up to 6 over it, golden hour the afternoon under 15, morning until three hours before solar noon.
    static func of(elevation e: Double, hourAngle h: Double) -> TimeOfDay {
        let rising = h < 0
        if e < -6 { return .night }
        if e < -0.833 { return rising ? .dawn : .dusk }
        if e < 6 { return rising ? .sunrise : .sunset }
        if !rising && e < 15 { return .golden }
        return h < -45 ? .morning : .midday
    }

    /// A sun height that looks like this time of day, for a fixed light.
    var elevation: Double {
        switch self {
        case .dawn, .dusk: return -4
        case .sunrise: return 2
        case .morning: return 20
        case .midday: return 50
        case .golden: return 8
        case .sunset: return 1
        case .night: return -20
        }
    }
}
