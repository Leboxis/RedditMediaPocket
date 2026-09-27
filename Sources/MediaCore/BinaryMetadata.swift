import Foundation

/// Métadonnées binaires visibles dans l'Explorateur Windows :
/// `Auteurs = collection` (`u/pseudo`, `r/sub`, `saved/pseudo`),
/// `Commentaires = lien du post Reddit`.
/// JPG/PNG via EXIF (Artist/UserComment), MP4 via ©ART/©cmt.
/// GIF/WebP exclus : mal supportés par l'Explorateur et par `CopyImageSource`.
public enum BinaryMetadata {
    public struct Payload: Equatable {
        public let author: String
        public let comment: String?
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]
    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    public static func supportsExtension(_ ext: String) -> Bool {
        let clean = ext.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return imageExtensions.contains(clean) || videoExtensions.contains(clean)
    }

    /// Lien du post : `<link href>` du flux si https valide, sinon
    /// `https://www.reddit.com/comments/<id>/` reconstruit depuis `t3_…`.
    public static func postLink(postID: String, link: String?) -> String? {
        if let link = link?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty,
           link.lowercased().hasPrefix("https://"), URL(string: link) != nil {
            return link
        }
        var short = postID.trimmingCharacters(in: .whitespacesAndNewlines)
        if short.lowercased().hasPrefix("t3_") { short = String(short.dropFirst(3)) }
        short = short.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !short.isEmpty, short.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else { return nil }
        return "https://www.reddit.com/comments/\(short)/"
    }

    public static func payload(author: String, postLink: String?) -> Payload {
        let cleanAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLink = postLink?.trimmingCharacters(in: .whitespacesAndNewlines)
        let authorValue = String(cleanAuthor.prefix(256))
        let linkValue = cleanLink.flatMap { $0.isEmpty ? nil : String($0.prefix(2048)) }
        return Payload(author: authorValue, comment: linkValue)
    }
}
