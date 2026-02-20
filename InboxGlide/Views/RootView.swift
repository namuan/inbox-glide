import SwiftUI

struct RootView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    
    @State private var showingOnboarding = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DeckView()
        }
        .toolbar {
            ToolbarItemGroup {
                if mailStore.isSyncing {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Syncing: \(mailStore.syncingProvidersLabel)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(.separator.opacity(0.65), lineWidth: 1)
                    )
                    .help("Background sync in progress")
                }

                if preferences.unifiedInboxEnabled {
                    Button {
                        mailStore.selectedAccountID = nil
                    } label: {
                        Label("Unified View", systemImage: "tray.full")
                    }
                    .disabled(mailStore.selectedAccountID == nil)
                    .help("Show messages from all connected accounts")
                }

                if networkMonitor.isOnline {
                    if mailStore.queuedActions.count > 0 {
                        Button {
                            mailStore.syncIfPossible()
                        } label: {
                            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .help("Sync \(mailStore.queuedActions.count) queued actions")
                    }
                } else {
                    Label("Offline", systemImage: "wifi.slash")
                        .foregroundStyle(.secondary)
                        .help("Offline: actions will queue and sync later")
                }
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .sheet(isPresented: $showingOnboarding) {
            OnboardingView()
                .environmentObject(preferences)
                .environmentObject(mailStore)
        }
        .onAppear {
            if !preferences.hasCompletedOnboarding && mailStore.accounts.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showingOnboarding = true
                }
            }
        }
    }
}
