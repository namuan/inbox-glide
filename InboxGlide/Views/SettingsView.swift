import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GlideSettingsView()
                .tabItem { Label("Glide", systemImage: "hand.draw") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            NotificationsSettingsView()
                .tabItem { Label("Notifications", systemImage: "bell") }
            AccountsSettingsView()
                .tabItem { Label("Accounts", systemImage: "person.2") }
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
            PrivacySettingsView()
                .tabItem { Label("Privacy", systemImage: "lock") }
        }
        .padding(12)
        .frame(width: 720, height: 520)
    }
}
