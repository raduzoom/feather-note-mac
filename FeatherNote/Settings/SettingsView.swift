import AppKit
import FeatherCore
import SwiftUI

/// Settings: General, Sync and Advanced.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Form {
                Picker("Quick notes go to:", selection: $model.quickNoteNotebookID) {
                    Text("No Notebook").tag(ULID?.none)
                    ForEach(model.notebooks) { Text($0.name).tag(ULID?.some($0.id)) }
                }
                Text("You can still pick another notebook in the quick note window.")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.textSecondary)
                Picker("Empty Trash after:", selection: $model.trashRetentionDays) {
                    ForEach(AppModel.retentionChoices, id: \.self) { Text("\($0) days").tag($0) }
                }
                Text("Notes in the Trash are removed for good after this.")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.textSecondary)
                LabeledContent("Quick note shortcut:") {
                    ShortcutRecorder(model: model)
                }
                Text(model.quickNoteShortcutError
                     ?? "If the shortcut doesn't open a quick note, another app is using it: pick another.")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(Spacing.s32)
            .tabItem { Label("General", systemImage: "gearshape") }

            ScrollView {
                SyncSettingsView(model: model).padding(Spacing.s32)
            }
            .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }

            AdvancedSettingsView(cloud: model.cloud)
                .padding(Spacing.s32)
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 600)
    }
}

/// Shows the shortcut and records a new one after "Change…": the next key-down with ⌘, ⌥ or ⌃; Esc cancels.
private struct ShortcutRecorder: View {
    @Bindable var model: AppModel
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: Spacing.s8) {
            Text(recording ? "Type a shortcut…" : model.quickNoteShortcut.display)
                .font(Theme.uiLabelStrong)
                .monospacedDigit()
            Button(recording ? "Cancel" : "Change…") { recording ? stop() : start() }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }   // Esc
            guard let shortcut = Shortcut(event: event) else { return nil }
            model.changeQuickNoteShortcut(shortcut)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
