import Foundation

/// Reddit ne sert plus les flux `.rss` sur `www.reddit.com` : ces adresses
/// répondent désormais un document Atom « Not Found » émis par
/// `rss.reddit.com` (HTTP 404), y compris pour les subreddits publics
/// (`/r/<sub>/.rss`) et les profils (`/user/<nom>/submitted.rss`).
///
/// Le même chemin reste servi par `old.reddit.com`, qui est déjà l'hôte des
/// pages de préférences privées (`prefs/feeds`) : c'est donc le repli
/// naturel, et il porte les cookies de session comme l'hôte d'origine.
/// Ce repli est une hypothèse tant qu'un flux n'a pas été lu avec succès :
/// `Network` journalise les deux tentatives pour trancher au premier essai.
public enum RedditFeedHosts {
    /// Hôte de repli d'une adresse de flux, ou `nil` quand il n'y a rien à
    /// retenter : autre hôte, autre forme d'adresse, ou adresse déjà sur le
    /// repli (la seconde tentative ne peut pas boucler).
    public static func fallback(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "www.reddit.com",
              url.path.lowercased().contains(".rss") else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.host = "old.reddit.com"
        return parts?.url
    }
}
