import FeatherCore
import SwiftUI

@main
struct FeatherNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The main window is AppKit-hosted (see AppDelegate). SwiftUI provides Settings and the menus.
        Settings {
            if let model = appDelegate.model {
                SettingsView(model: model)
            }
        }
        .commands {
            AppCommands(model: appDelegate.model, dialogs: appDelegate.dialogs, showWindow: { appDelegate.showMainWindow() })
        }
    }
}

/// Shown instead of the app when the library can't be opened.
struct LibraryOpenFailure: View {
    let error: Error

    var body: some View {
        Text(message)
            .multilineTextAlignment(.center)
            .padding(48)
            .frame(minWidth: 480, minHeight: 240)
    }

    private var message: String {
        if case LibraryError.newerSchema = error {
            return "This library was made by a newer FeatherMark. Update the app to open it."
        }
        return "FeatherMark couldn't open your library.\n\(error.localizedDescription)"
    }
}
