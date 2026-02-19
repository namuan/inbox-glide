import AppKit
import SwiftUI

struct PrivacySettingsView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore

    @State private var isConfirmingDeleteAll: Bool = false

    var body: some View {
        Form {
            Section("Data") {
                Button("Export Data (JSON)…") {
                    export()
                }

                Button("Delete All Local Data…", role: .destructive) {
                    isConfirmingDeleteAll = true
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Privacy")
        .alert("Delete All Data", isPresented: $isConfirmingDeleteAll) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                mailStore.deleteAllData()
            }
        } message: {
            Text("This deletes local accounts, emails, and queued actions from this Mac.")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "InboxGlide-export.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try mailStore.exportData(to: url)
            } catch {
                mailStore.errorAlert = ErrorAlert(title: "Export failed", message: error.localizedDescription)
            }
        }
    }
}
