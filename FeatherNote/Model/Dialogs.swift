import Foundation
import Observation

/// Pending alerts: a name prompt, a destructive confirmation, or an information message.
@MainActor @Observable
final class Dialogs {
    struct NameRequest: Identifiable {
        let id = UUID()
        var title: String
        var placeholder: String
        var initial: String
        var button: String
        var onSubmit: (String) async -> Void
    }

    struct ConfirmRequest: Identifiable {
        let id = UUID()
        var confirmation: Formatting.Confirmation
        var onConfirm: () async -> Void
    }

    struct Message: Identifiable {
        let id = UUID()
        var title: String
        var body: String
    }

    var name: NameRequest?
    var confirmRequest: ConfirmRequest?
    var message: Message?

    func askName(title: String, placeholder: String, initial: String = "", button: String, onSubmit: @escaping (String) async -> Void) {
        name = NameRequest(title: title, placeholder: placeholder, initial: initial, button: button, onSubmit: onSubmit)
    }

    func confirm(_ confirmation: Formatting.Confirmation, onConfirm: @escaping () async -> Void) {
        confirmRequest = ConfirmRequest(confirmation: confirmation, onConfirm: onConfirm)
    }

    func show(title: String, body: String) {
        message = Message(title: title, body: body)
    }
}
