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

    /// Optional advisory headers; their absence does not imply an anonymous quota.
    public static func quotaDelay(remaining: String?, reset: String?) -> TimeInterval? {
        guard let remaining = remaining.flatMap(Double.init), remaining.isFinite, remaining >= 0,
              let reset = reset.flatMap(Double.init), reset.isFinite, reset > 0 else { return nil }
        return remaining < 1 ? reset : reset / remaining
    }

    public static func retryDate(header: String?, now: Date) -> Date {
        let value = (header ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(max(1, seconds))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        if let date = formatter.date(from: value), date > now { return date }
        return now.addingTimeInterval(900)
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
