import SwiftUI
import UIKit
import Observation
import Foundation

/// Garde l'écran allumé pendant les transferts actifs — téléchargements et envois
/// kDrive — et rétablit la veille automatique dès qu'il n'y en a plus.
///
/// Sur iOS, `UIApplication.shared.isIdleTimerDisabled` est l'API prévue à cet
/// effet. Elle bloque seulement la mise en veille automatique : l'utilisateur
/// peut toujours verrouiller l'écran lui-même, et iOS reprend la main dès que
/// l'application quitte le premier plan.
@MainActor
final class IdleTimerGuard {
    static let shared = IdleTimerGuard()

    private var telechargementActif = false
    private var envoiContinuActif = false
    private var envoiLotActif = false
    private var premierPlan = true
    private var observationGeneration = 0

    private init() {}

    /// Observe les trois sources de transfert via le suivi d'observations
    /// (macro `@Observable`) : chaque changement de l'une des propriétés
    /// suivies relance la boucle et réévalue la veille. À appeler une fois
    /// avec le téléchargeur possédé par l'écran principal.
    func surveiller(_ downloader: Downloader) {
        observationGeneration &+= 1
        let generation = observationGeneration
        telechargementActif = downloader.running
        envoiContinuActif = KDriveContinuousUploadController.shared.isUploading
        envoiLotActif = KDriveService.shared.isUploading
        appliquer()
        observerSuivant(downloader, generation: generation)
    }

    func scenePhaseDidChange(_ phase: ScenePhase) {
        premierPlan = (phase == .active)
        appliquer()
    }

    private func observerSuivant(_ downloader: Downloader, generation: Int) {
        withObservationTracking {
            _ = downloader.running
            _ = KDriveContinuousUploadController.shared.isUploading
            _ = KDriveService.shared.isUploading
        } onChange: {
            Task { @MainActor in
                self.reevaluer(downloader, generation: generation)
            }
        }
    }

    private func reevaluer(_ downloader: Downloader, generation: Int) {
        guard observationGeneration == generation else { return }
        telechargementActif = downloader.running
        envoiContinuActif = KDriveContinuousUploadController.shared.isUploading
        envoiLotActif = KDriveService.shared.isUploading
        appliquer()
        observerSuivant(downloader, generation: generation)
    }

    private func appliquer() {
        let transfertActif = telechargementActif || envoiContinuActif || envoiLotActif
        let desactiverVeille = transfertActif && premierPlan
        guard UIApplication.shared.isIdleTimerDisabled != desactiverVeille else { return }
        UIApplication.shared.isIdleTimerDisabled = desactiverVeille
    }
}
