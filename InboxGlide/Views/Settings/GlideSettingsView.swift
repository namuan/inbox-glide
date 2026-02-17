import SwiftUI

struct GlideSettingsView: View {
    @EnvironmentObject private var preferences: PreferencesStore

    var body: some View {
        Form {
            Section("Primary Actions") {
                actionPicker("Left", selection: $preferences.leftPrimaryAction)
                actionPicker("Right", selection: $preferences.rightPrimaryAction)
                actionPicker("Up", selection: $preferences.upPrimaryAction)
                actionPicker("Down", selection: $preferences.downPrimaryAction)
            }

            Section("Option/Alt Secondary Actions") {
                actionPicker("Left", selection: $preferences.leftSecondaryAction)
                actionPicker("Right", selection: $preferences.rightSecondaryAction)
                actionPicker("Up", selection: $preferences.upSecondaryAction)
                actionPicker("Down", selection: $preferences.downSecondaryAction)
            }

            Section {
                Toggle("Confirm destructive actions", isOn: $preferences.confirmDestructiveActions)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Glide")
    }

    private func actionPicker(_ label: String, selection: Binding<GlideAction>) -> some View {
        Picker(label, selection: selection) {
            ForEach(GlideAction.supportedInUI) { action in
                Label(action.displayName, systemImage: action.systemImage)
                    .tag(action)
            }
        }
    }
}
