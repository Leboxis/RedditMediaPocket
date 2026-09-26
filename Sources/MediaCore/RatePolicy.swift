import Foundation

public enum RatePolicy {
    // Related CDN/API hosts share a limit; changing subdomains cannot bypass it.
    public static func service(for host: String) -> String {
        let host = host.lowercased()
        if host == "reddit.com" || host.hasSuffix(".reddit.com") || host == "redd.it" || host.hasSuffix(".redd.it") { return "Reddit" }
        if host == "redgifs.com" || host.hasSuffix(".redgifs.com") { return "RedGIFs" }
        if host == "imgur.com" || host.hasSuffix(".imgur.com") { return "Imgur" }
        return host
    }

    /// Server-stated deadline for a refused request, or nil when the server
    /// states none. Reddit's RSS endpoints answer 429 with `x-ratelimit-reset`
    /// and no `Retry-After`, so the reset is read as a fallback. Nothing is
    /// invented: a nil deadline keeps a manual restart immediately possible.
    public static func retryDate(retryAfter: String?, reset: String?, now: Date) -> Date? {
        if let date = absolute(retryAfter, now: now) { return date }
        guard let seconds = reset.flatMap(Double.init), seconds.isFinite, seconds > 0 else { return nil }
        return now.addingTimeInterval(seconds)
    }

    /// `Retry-After` carries either a delay in seconds or an absolute HTTP date.
    private static func absolute(_ header: String?, now: Date) -> Date? {
        let value = (header ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        if let date = formatter.date(from: value), date > now { return date }
        return nil
    }
}

public struct ServiceLimits {
    public private(set) var deadlines: [String: Date]
    public init(deadlines: [String: Date] = [:]) { self.deadlines = deadlines }
    public mutating func record(service: String, until date: Date) {
        deadlines[service] = max(deadlines[service] ?? .distantPast, date)
    }
    public func blockedUntil(service: String, now: Date) -> Date? {
        guard let date = deadlines[service], date > now else { return nil }
        return date
    }
}
