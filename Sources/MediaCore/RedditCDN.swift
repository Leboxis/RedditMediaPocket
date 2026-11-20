import Foundation

/// Replis CDN des médias Reddit hébergés.
///
/// Règles constatées en novembre 2026 :
/// - `i.redd.it/<id>.<ext>` ne sert le média que si l'extension est **exacte**
///   (les médias récents sont en `.jpeg`, pas `.jpg`) et/ou avec un contexte
///   navigateur ; sinon HTTP 404. Aucun repli par simple réécriture d'hôte.
/// - `preview.redd.it/<id>.<ext>` **sans** la signature de la query string
///   répond HTTP 403 ; `external-preview.redd.it` ne sert pas les médias
///   natifs de Reddit. Le seul miroir fiable est donc l'URL signée complète
///   fournie par le JSON (`media_metadata[id].s.u` / `preview.images[].source.url`).
public enum RedditCDN {
    /// Repli d'une URL de média Reddit hébergé.
    ///
    /// Pour une URL signée `preview.redd.it` / `external-preview.redd.it`, le
    /// repli est l'original `i.redd.it/<nom>.<vraie extension>` déduit du
    /// chemin de l'URL signée (l'extension y est réelle, ex. `.jpeg`). Pour
    /// `i.redd.it`, aucun repli : la réponse est 404 hors navigateur et le
    /// preview non signé 403 — les miroirs utiles viennent des métadonnées du
    /// post (voir `Post.galleryMedia` et les miroirs déclarés par post).
    public static func fallbacks(for url: URL) -> [URL] {
        guard url.scheme?.lowercased() == "https" else { return [] }
        let host = url.host?.lowercased()
        guard host == "preview.redd.it" || host == "external-preview.redd.it" else { return [] }
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        guard !name.isEmpty, !ext.isEmpty,
              let original = URL(string: "https://i.redd.it/\(name).\(ext)") else { return [] }
        return [original]
    }
}
