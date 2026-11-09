import SwiftUI

/// Settings: General and Advanced (Sync arrives with Feather Cloud in Phase 8).
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            Form {
                Picker("Empty Trash after:", selection: $model.trashRetentionDays) {
                    ForEach(AppModel.retentionChoices, id: \.self) { Text("\($0) days").tag($0) }
                }
                Text("Notes in the Trash are removed for good after this.")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(Spacing.s32)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                TextField("Server URL:", text: .constant(""), prompt: Text("https://cloud.feathernote.app"))
                    .disabled(true)
                Text("Custom servers arrive with Feather Cloud sync.")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(Spacing.s32)
            .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 600)
    }
}
