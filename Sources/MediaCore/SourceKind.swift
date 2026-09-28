/// The four faces of the existing source button, in display order.
public enum SourceKind: String, CaseIterable, Sendable {
    case user = "u"
    case subreddit = "r"
    case saved
    case xFetish = "x"

    public var next: SourceKind {
        switch self {
        case .user: return .subreddit
        case .subreddit: return .saved
        case .saved: return .xFetish
        case .xFetish: return .user
        }
    }
}
