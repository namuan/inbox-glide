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
            }

            Section("Email Summary") {
                Picker("Length", selection: $preferences.aiSummaryLength) {
                    ForEach(AISummaryLength.allCases) { length in
                        Text(length.displayName).tag(length)
                    }
                }
                .pickerStyle(.segmented)

                Text("Short keeps summaries compact, Medium balances length and detail, and Full asks AI for comprehensive coverage across long emails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Email summaries run on-device when available. If unavailable, the app falls back to a local rule-based summary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("PII scrubbing happens locally before any cloud call. Cloud mode is a stub in this prototype.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI")
    }
}
