import Foundation
import MediaCore
import Photos

enum GallerySaveError: LocalizedError {
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return L("Autorise l’ajout à Photos dans Réglages > Confidentialité > Photos pour enregistrer les médias.",
                     "Allow adding to Photos in Settings > Privacy > Photos to save media.")
        }
    }
}

/// Enregistre des fichiers déjà téléchargés dans la photothèque.
///
/// `PHAssetCreationRequest` copie les fichiers référencés : aucun média n'est
/// décodé en mémoire, et un lot entier part dans une seule transaction Photos.
enum GallerySave {
    static func save(_ urls: [URL]) async throws {
        guard !urls.isEmpty else { return }

        var status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        guard status == .authorized || status == .limited else {
            throw GallerySaveError.notAuthorized
        }

        try await PHPhotoLibrary.shared().performChanges {
            for url in urls {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = url.lastPathComponent
                request.addResource(with: isVideo(url) ? .video : .photo, fileURL: url, options: options)
            }
        }
    }
}
