import Foundation

public enum XTwitterError: LocalizedError {
    case invalidUsername, loginRequired, unknownAccount, deniedAccess, invalidTimeline, tooManyPages

    public var errorDescription: String? {
        switch self {
        case .invalidUsername:
            return L("Pseudo X invalide (1 à 15 lettres, chiffres ou underscores, ex. tw/pseudo).", "Invalid X username (1 to 15 letters, digits or underscores, e.g. tw/username).")
        case .loginRequired:
            return L("Connecte-toi à X dans les Réglages : les médias d'un profil exigent une session.", "Sign in to X in Settings: a profile's media requires a session.")
        case .unknownAccount:
            return L("Compte X introuvable ou protégé : les médias publics de ce profil sont inaccessibles.", "X account not found or protected: this profile's public media is inaccessible.")
        case .deniedAccess:
            return L("X refuse l'accès aux médias (HTTP 403 ou 401). L'interface de X a peut-être changé.", "X denied media access (HTTP 403 or 401). X's interface may have changed.")
        case .invalidTimeline:
            return L("Fil des médias X illisible ou tronqué.", "X media timeline is unreadable or truncated.")
        case .tooManyPages:
            return L("Trop de pages de médias X à parcourir.", "Too many X media pages to scan.")
        }
    }
}

/// Surface publique de x.com utilisée par la source `tw/`. X n'expose aucun
/// accès anonyme aux médias : chaque requête passe par l'API GraphQL interne,
/// qui exige les cookies de session (`auth_token`, `ct0`) obtenues via WebKit
/// (voir `XSession`). Les `queryId` ci-dessous sont publiés par le bundle web de
/// x.com et changent quand X met à jour son front ; ils sont regroupés ici pour
/// être remplacés en un seul endroit quand cela arrive.
public enum XTwitterAPI {
    /// Jeton public embarqué dans le client web. Il n'est pas secret et ne
    /// remplace pas la session : sans `auth_token`, x.com répond HTTP 403.
    public static let bearer = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCO4W5svLiN1JqbuTsaOgC8R4vKgrbJ0C3M4jQhbSy1w7u"

    /// `queryId` relevés dans le bundle web de x.com. Un `queryId` périmé se
    /// manifeste par une réponse sans `entries` ; `invalidTimeline` le dit
    /// explicitement plutôt que de rapporter « aucun média ».
    public enum Query {
        /// Résout un `@pseudo` en identifiant numérique, nécessaire aux pages
        /// suivantes.
        public static let userByScreenName = "WU4yX3X0Z4VdQv9Fq1cY1w"
        /// Fil `/media` d'un compte : uniquement les posts qui portent un média.
        public static let userMedia = "ZsExXCi3SqC3D8C5YCVXKA"
    }

    /// Drapeaux de fonctionnalités que x.com valide sur chaque appel. Ils
    /// conditionnent la forme de la réponse ; les omettre ferait rejeter la requête.
    static let commonFeatures = [
        #""rweb_tweetviewer_omnimodal":true"#,
        #""profile_and_omnimodal":true"#,
        #""tweet_awards":true"#,
        #""tweet_creator_enabled":true"#,
        #""tweet_results_ui_omnimodal":true"#,
        #""responsive_web_graphql_user_by_screen_name":true"#,
        #""responsive_web_graphql_user_media":true"#,
        #""responsive_web_graphql_timeline_navigation":true"#
    ].joined(separator: ",").wrapped(in: "{", and: "}")

    /// `UserByScreenName` : `@pseudo` → identifiant numérique.
    public static func userByScreenName(username: String) -> URL {
        graphqlURL(queryID: Query.userByScreenName, operation: "UserByScreenName",
                    variables: #"{"screen_name":"\#(jsonEscape(username))","withSafetyModeUserFields":true}"#)
    }

    /// `UserMedia` : une page du fil `/media` du compte. `cursor` nil = première
    /// page ; sinon le curseur `Bottom` de la page précédente.
    public static func userMedia(userID: String, cursor: String?) -> URL {
        // Une chaîne brute `#"…"#` ne peut pas s'étendre sur plusieurs lignes :
        // le texte est donc assemblé par morceaux plutôt que sur une ligne
        // unique devenue illisible.
        var variables = #"{"userId":"\#(jsonEscape(userID))","count":40"# + ","
        variables += #""includePromotedContent":false"# + ","
        variables += #""withQuickPromoteEligibilityTweetFields":true"# + ","
        variables += #""withVoice":true"#
        if let cursor, !cursor.isEmpty {
            variables += #","cursor":"\#(jsonEscape(cursor))""#
        }
        variables += "}"
        return graphqlURL(queryID: Query.userMedia, operation: "UserMedia", variables: variables)
    }

    private static func graphqlURL(queryID: String, operation: String, variables: String) -> URL {
        var components = URLComponents(string: "https://x.com/i/api/graphql/\(queryID)/\(operation)")!
        components.queryItems = [
            URLQueryItem(name: "variables", value: variables),
            URLQueryItem(name: "features", value: commonFeatures)
        ]
        return components.url!
    }

    /// Un pseudo X fait 1 à 15 caractères : lettres, chiffres ou underscore. Les
    /// noms d'affichage (espaces, accents) sont refusés, ils ne sont pas
    /// utilisables dans une adresse de profil.
    public static func username(_ text: String) throws -> String {
        var name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasPrefix("tw/") { name = String(name.dropFirst(3)) }
        else if name.hasPrefix("@") { name = String(name.dropFirst()) }
        // Accepte une adresse de profil collée depuis un partage : `x.com/pseudo`,
        // `https://www.twitter.com/pseudo/media`. L'ancre `//` ou le début de
        // chaîne évite de capturer un `x.com/` au milieu d'un autre texte.
        if let range = name.range(of: "(?:^|//)(?:www\\.)?(?:x|twitter)\\.com/", options: .regularExpression) {
            name = String(name[range.upperBound...])
            name = String(name.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.range(of: "^[A-Za-z0-9_]{1,15}$", options: .regularExpression) != nil else {
            throw XTwitterError.invalidUsername
        }
        return name
    }

    /// En-têtes des appels API. `ct0` est le jeton CSRF, renvoyé par X dans un
    /// cookie et exigé en `x-csrf-token` sur chaque requête authentifiée.
    /// Le cookie lui-même est posé par `XSession` et filtré par `XTwitterCookiePolicy`.
    public static func headers(csrf: String) -> [String: String] {
        [
            "Accept": "application/json",
            "x-twitter-active-user": "yes",
            "x-twitter-client-language": "en",
            "x-csrf-token": csrf
        ]
    }

    static func jsonEscape(_ value: String) -> String {
        var out = ""
        for character in value.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 { out += String(format: "\\u%04x", character.value) }
                else { out.unicodeScalars.append(character) }
            }
        }
        return out
    }
}

/// Quels hôtes reçoivent les cookies de session X. Le CDN média
/// (`pbs.twimg.com`, `video.twimg.com`) en est volontairement exclu : ces
/// fichiers sont publics et les identifiants de session ne doivent jamais
/// quitter `x.com`. Modèle calqué sur `RedditCookiePolicy`.
public enum XTwitterCookiePolicy {
    public static func allows(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "x.com" || host.hasSuffix(".x.com")
            || host == "twitter.com" || host.hasSuffix(".twitter.com")
    }

    /// `ct0` est un cookie de domaine `x.com` : il doit traverser tous les
    /// appels API.
    public static func csrfToken(cookies: [HTTPCookie]) -> String? {
        cookies.first { $0.name == "ct0" && !$0.value.isEmpty }?.value
    }

    public static func header(cookies: [HTTPCookie], for url: URL, now: Date = Date()) -> String? {
        guard allows(url), let host = url.host?.lowercased() else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let matching = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            let isXDomain = bare == "x.com" || bare.hasSuffix(".x.com")
                || bare == "twitter.com" || bare.hasSuffix(".twitter.com")
            guard isXDomain else { return false }
            let hostMatches = domain.hasPrefix(".")
                ? host == bare || host.hasSuffix("." + bare)
                : host == bare || host.hasSuffix("." + bare)
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            let pathMatches = path == cookiePath || (path.hasPrefix(cookiePath) && (cookiePath.hasSuffix("/") || path.dropFirst(cookiePath.count).hasPrefix("/")))
            return hostMatches && pathMatches && (cookie.expiresDate == nil || cookie.expiresDate! > now)
        }
        guard !matching.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }
}