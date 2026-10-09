import Foundation

public enum XTwitterError: LocalizedError {
    case invalidUsername, loginRequired, unknownAccount, deniedAccess, unavailableAPI, invalidTimeline, tooManyPages

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
        case .unavailableAPI:
            return L("La route API X est indisponible (HTTP 404). Cela ne signifie pas que le compte est introuvable.", "The X API route is unavailable (HTTP 404). This does not mean the account is missing.")
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
    public static let bearer = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"

    /// Routes et paramètres alignés sur twikit/client/gql.py et constants.py.
    /// Une route périmée peut renvoyer HTTP 404, distinct d’un compte absent.
    public enum Query {
        /// Résout un `@pseudo` en identifiant numérique, nécessaire aux pages
        /// suivantes.
        public static let userByScreenName = "NimuplG1OB7Fd2btCLdBOw"
        /// Fil `/media` d'un compte : uniquement les posts qui portent un média.
        public static let userMedia = "2tLOJWwGuCTytDrGBg8VwQ"
    }

    /// Drapeaux de fonctionnalités que x.com valide sur chaque appel. Ils
    /// conditionnent la forme de la réponse ; les omettre ferait rejeter la requête.
    // Paramètres des opérations utilisés par Twikit (twikit/constants.py).
    static let userFeatures = #"{"hidden_profile_likes_enabled":true,"hidden_profile_subscriptions_enabled":true,"responsive_web_graphql_exclude_directive_enabled":true,"verified_phone_label_enabled":false,"subscriptions_verification_info_is_identity_verified_enabled":true,"subscriptions_verification_info_verified_since_enabled":true,"highlights_tweets_tab_ui_enabled":true,"responsive_web_twitter_article_notes_tab_enabled":false,"creator_subscriptions_tweet_preview_api_enabled":true,"responsive_web_graphql_skip_user_profile_image_extensions_enabled":false,"responsive_web_graphql_timeline_navigation_enabled":true}"#
    static let mediaFeatures = #"{"creator_subscriptions_tweet_preview_api_enabled":true,"c9s_tweet_anatomy_moderator_badge_enabled":true,"tweetypie_unmention_optimization_enabled":true,"responsive_web_edit_tweet_api_enabled":true,"graphql_is_translatable_rweb_tweet_is_translatable_enabled":true,"view_counts_everywhere_api_enabled":true,"longform_notetweets_consumption_enabled":true,"responsive_web_twitter_article_tweet_consumption_enabled":true,"tweet_awards_web_tipping_enabled":false,"longform_notetweets_rich_text_read_enabled":true,"longform_notetweets_inline_media_enabled":true,"rweb_video_timestamps_enabled":true,"responsive_web_graphql_exclude_directive_enabled":true,"verified_phone_label_enabled":false,"freedom_of_speech_not_reach_fetch_enabled":true,"standardized_nudges_misinfo":true,"tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled":true,"responsive_web_media_download_video_enabled":false,"responsive_web_graphql_skip_user_profile_image_extensions_enabled":false,"responsive_web_graphql_timeline_navigation_enabled":true,"responsive_web_enhance_cards_enabled":false}"#

    /// `UserByScreenName` : `@pseudo` → identifiant numérique.
    public static func userByScreenName(username: String) -> URL {
        graphqlURL(queryID: Query.userByScreenName, operation: "UserByScreenName",
                    variables: #"{"screen_name":"\#(jsonEscape(username))","withSafetyModeUserFields":false}"#,
                    features: userFeatures, fieldToggles: #"{"withAuxiliaryUserLabels":false}"#)
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
        variables += #""withVoice":true,"withV2Timeline":true"#
        if let cursor, !cursor.isEmpty {
            variables += #","cursor":"\#(jsonEscape(cursor))""#
        }
        variables += "}"
        return graphqlURL(queryID: Query.userMedia, operation: "UserMedia", variables: variables, features: mediaFeatures)
    }

    private static func graphqlURL(queryID: String, operation: String, variables: String, features: String, fieldToggles: String? = nil) -> URL {
        var components = URLComponents(string: "https://x.com/i/api/graphql/\(queryID)/\(operation)")!
        components.queryItems = [
            URLQueryItem(name: "variables", value: variables),
            URLQueryItem(name: "features", value: features)
        ]
        if let fieldToggles { components.queryItems?.append(URLQueryItem(name: "fieldToggles", value: fieldToggles)) }
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
            "x-twitter-auth-type": "OAuth2Session",
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
    public static func csrfToken(cookies: [HTTPCookie], now: Date = Date()) -> String? {
        matchingCookies(cookies, for: XTwitterAPI.userByScreenName(username: "x"), now: now)
            .first { $0.name == "ct0" && !$0.value.isEmpty }?.value
    }

    /// Session WebKit détectée dès qu'un auth_token X non expiré existe.
    /// ct0 reste obligatoire pour les appels GraphQL authentifiés.
    public static func hasLoginCookie(cookies: [HTTPCookie], now: Date = Date()) -> Bool {
        matchingCookies(cookies, for: XTwitterAPI.userByScreenName(username: "x"), now: now)
            .contains { $0.name == "auth_token" && !$0.value.isEmpty }
    }

    public static func hasCredentials(cookies: [HTTPCookie], now: Date = Date()) -> Bool {
        let matching = matchingCookies(cookies, for: XTwitterAPI.userByScreenName(username: "x"), now: now)
        return ["auth_token", "ct0"].allSatisfy { name in
            matching.contains { $0.name == name && !$0.value.isEmpty }
        }
    }

    public static func header(cookies: [HTTPCookie], for url: URL, now: Date = Date()) -> String? {
        let matching = matchingCookies(cookies, for: url, now: now)
        guard !matching.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: matching)["Cookie"]
    }

    private static func matchingCookies(_ cookies: [HTTPCookie], for url: URL, now: Date) -> [HTTPCookie] {
        guard allows(url), let host = url.host?.lowercased() else { return [] }
        let path = url.path.isEmpty ? "/" : url.path
        return cookies.filter { cookie in
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
    }
}
