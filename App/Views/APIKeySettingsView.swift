import SwiftUI
import MediaCore

/// Écran minimal pour enregistrer la clé API dans le Keychain de l'iPhone.
struct APIKeySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cle = ""
    @State private var message = ""
    @State private var cleEnregistree = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(L("Clé API", "API key"), text: $cle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text(L("Backend Cloudflare", "Cloudflare backend"))
                } footer: {
                    Text(L("La clé est gardée dans le Keychain de l'iPhone. Elle n'est jamais écrite dans le code ni dans les réglages ordinaires.", "The key is kept in the iPhone Keychain. It is never written in code or regular settings."))
                }

                Section {
                    Button(L("Enregistrer la clé", "Save key")) {
                        enregistrer()
                    }
                    .disabled(cle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if cleEnregistree {
                        Button(L("Supprimer la clé", "Delete key"), role: .destructive) {
                            supprimer()
                        }
                    }
                }

                if !message.isEmpty {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(L("Clé API", "API key"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .task { cleEnregistree = KeychainStore.get() != nil }
        }
    }

    private func enregistrer() {
        let valeur = cle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !valeur.isEmpty else { return }
        do {
            try KeychainStore.set(valeur)
            cleEnregistree = true
            message = L("Clé enregistrée avec succès.", "Key saved successfully.")
            cle = ""
            dismiss()
            // Après réinstallation, la clé a été effacée : on relance la restauration.
            Task { await SyncService.shared.restaurer() }
        } catch {
            message = L("Enregistrement impossible : \(error.localizedDescription)", "Could not save: \(error.localizedDescription)")
        }
    }

    private func supprimer() {
        do {
            try KeychainStore.delete()
            cleEnregistree = false
            message = L("Clé supprimée.", "Key deleted.")
        } catch {
            message = L("Suppression impossible : \(error.localizedDescription)", "Could not delete: \(error.localizedDescription)")
        }
    }
}
