/// The faces of the existing source button, in display order.
public enum SourceKind: String, CaseIterable, Sendable {
    case user = "u"
    case subreddit = "r"
    case redGifs = "rg"
    case saved
    case xFetish = "x"
    case twitter = "tw"

    public var next: SourceKind {
        switch self {
        case .user: return .subreddit
        case .subreddit: return .redGifs
        case .redGifs: return .saved
        case .saved: return .xFetish
        case .xFetish: return .twitter
        case .twitter: return .user
        }
    }
}
