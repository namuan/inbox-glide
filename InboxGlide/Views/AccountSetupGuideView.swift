import SwiftUI

struct AccountSetupGuideView: View {
    @EnvironmentObject private var mailStore: MailStore
    
    let onComplete: () -> Void
    let onBack: () -> Void
    
    @State private var selectedProvider: MailProvider = .gmail
    @State private var displayName: String = ""
    @State private var email: String = ""
    @State private var showingProviderInstructions = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Text("Add Your First Email Account")
                    .font(.title2.bold())
                
                Text("Choose your email provider and we'll guide you through the setup")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 32)
            
            // Content
            VStack(spacing: 24) {
                // Provider Selection
                VStack(alignment: .leading, spacing: 12) {
                    Text("Email Provider")
                        .font(.headline)
                    
                    HStack(spacing: 16) {
                        ForEach(MailProvider.allCases) { provider in
                            ProviderCard(
                                provider: provider,
                                isSelected: selectedProvider == provider,
                                action: { selectedProvider = provider }
                            )
                        }
                    }
                }
                
                // Account Details
                VStack(alignment: .leading, spacing: 12) {
                    Text("Account Information")
                        .font(.headline)
                    
                    VStack(spacing: 12) {
                        TextField("Display Name (e.g., Work, Personal)", text: $displayName)
                            .textFieldStyle(.roundedBorder)
                        
                        TextField("Email Address", text: $email)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                
                // Instructions Preview
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Next Step:")
                            .font(.headline)
                    }
                    
                    Text(providerInstructions)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
            .padding(.horizontal, 60)
            
            Spacer()
            
            // Actions
            HStack(spacing: 16) {
                Button("Back") {
                    onBack()
                }
                
                Spacer()
                
                Button("View Setup Instructions") {
                    showingProviderInstructions = true
                }
                .disabled(!isFormValid)
                
                Button("Add Account (Stub)") {
                    addAccount()
                }
                .disabled(!isFormValid)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 60)
            .padding(.bottom, 40)
        }
        .sheet(isPresented: $showingProviderInstructions) {
            ProviderInstructionsView(
                provider: selectedProvider,
                onDismiss: { showingProviderInstructions = false }
            )
        }
    }
    
    private var isFormValid: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var providerInstructions: String {
        switch selectedProvider {
        case .gmail:
            return "You'll need to authorize InboxGlide to access your Gmail account. We'll guide you through Google's OAuth flow."
        case .yahoo:
            return "You'll authorize InboxGlide with your Yahoo account. You can use OAuth or generate an app-specific password."
        case .fastmail:
            return "You'll connect to Fastmail using OAuth or an app password. We'll show you how to set this up."
        }
    }
    
    private func addAccount() {
        mailStore.addAccount(
            provider: selectedProvider,
            displayName: displayName,
            emailAddress: email
        )
        
        if mailStore.messages.isEmpty {
            mailStore.addSampleAccount()
        }
        
        onComplete()
    }
}

struct ProviderCard: View {
    let provider: MailProvider
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: provider.systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(isSelected ? .white : .blue)
                
                Text(provider.displayName)
                    .font(.headline)
                    .foregroundStyle(isSelected ? .white : .primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .background(isSelected ? Color.blue : Color.gray.opacity(0.1))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}
