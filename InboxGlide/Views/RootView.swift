import SwiftUI

struct RootView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore
    @EnvironmentObject private var networkMonitor: NetworkMonitor

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            DeckView()
        }
        .toolbar {
            ToolbarItemGroup {
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

                if preferences.smartCategoriesEnabled {
                    Menu {
                        Button("All") { mailStore.selectedCategory = nil }
                        Divider()
                        ForEach(MessageCategory.allCases) { category in
                            Button(category.displayName) { mailStore.selectedCategory = category }
                        }
                    } label: {
                        Label("Category", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
        }
        .frame(minWidth: 980, minHeight: 640)
    }
}
