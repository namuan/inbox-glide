import SwiftUI

struct AISettingsView: View {
    @EnvironmentObject private var preferences: PreferencesStore

    var body: some View {
        Form {
            Section("AI Reply") {
                Picker("Mode", selection: $preferences.aiMode) {
                    ForEach(AIMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Text("PII scrubbing happens locally before any cloud call. Cloud mode is a stub in this prototype.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI")
    }
}
