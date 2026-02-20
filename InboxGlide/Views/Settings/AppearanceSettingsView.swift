import SwiftUI

struct AppearanceSettingsView: View {
    @EnvironmentObject private var preferences: PreferencesStore

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Appearance", selection: $preferences.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Section("Cards") {
                Picker("Density", selection: $preferences.cardDensity) {
                    ForEach(CardDensity.allCases) { density in
                        Text(density.displayName).tag(density)
                    }
                }

                Picker("Email body", selection: $preferences.emailBodyDisplayMode) {
                    ForEach(EmailBodyDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Font size")
                    Slider(value: $preferences.fontScale, in: -2...4, step: 1)
                    Text(String(format: "%+.0f", preferences.fontScale))
                        .frame(width: 44, alignment: .trailing)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }
}
