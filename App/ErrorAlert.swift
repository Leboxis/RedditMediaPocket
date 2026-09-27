import SwiftUI

/// Keep error details in a native alert, including inside sheets and previews.
/// The separate presentation state lets a failed screen retain its Retry button
/// after dismissal without showing the error text inline or reopening the alert.
private struct ErrorAlert: ViewModifier {
    let message: String?
    let onDismiss: (() -> Void)?
    @State private var presentedMessage: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: message, initial: true) { _, value in
                presentedMessage = value
            }
            .alert("Pocket", isPresented: Binding(
                get: { presentedMessage != nil },
                set: { if !$0 { dismissAlert() } }
            )) {
                Button("OK", role: .cancel) { dismissAlert() }
            } message: {
                Text(presentedMessage ?? "")
            }
    }

    private func dismissAlert() {
        presentedMessage = nil
        onDismiss?()
    }
}

extension View {
    func errorAlert(_ message: String?, onDismiss: (() -> Void)? = nil) -> some View {
        modifier(ErrorAlert(message: message, onDismiss: onDismiss))
    }
}
