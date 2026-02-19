import SwiftUI

struct ProviderInstructionsView: View {
    let provider: MailProvider
    let onDismiss: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: provider.systemImage)
                    .font(.title)
                    .foregroundStyle(.blue)
                
                Text("\(provider.displayName) Setup Instructions")
                    .font(.title2.bold())
                
                Spacer()
                
                Button("Done") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    switch provider {
                    case .gmail:
                        GmailInstructions()
                    case .yahoo:
                        YahooInstructions()
                    case .fastmail:
                        FastmailInstructions()
                    }
                }
                .padding(32)
            }
        }
        .frame(width: 600, height: 500)
    }
}

struct GmailInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            InstructionSection(
                title: "Step 1: OAuth Authorization",
                icon: "shield.checkered",
                content: "Click 'Continue with Google' to authorize InboxGlide. You'll be taken to Google's secure login page."
            )
            
            InstructionSection(
                title: "Step 2: Grant Permissions",
                icon: "checkmark.shield",
                content: "InboxGlide needs permission to read and manage your emails. Google will show you exactly what we can access."
            )
            
            InstructionSection(
                title: "Step 3: Complete Setup",
                icon: "checkmark.circle",
                content: "After authorization, you'll return to InboxGlide and your account will be ready to use!"
            )
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.green)
                    Text("Privacy Note")
                        .font(.headline)
                }
                
                Text("InboxGlide never stores your emails on our servers. Everything stays on your Mac, encrypted and secure.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.green.opacity(0.1))
            .cornerRadius(8)
        }
    }
}

struct YahooInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            InstructionSection(
                title: "Option 1: OAuth (Recommended)",
                icon: "shield.checkered",
                content: "Click 'Continue with Yahoo' to securely authorize InboxGlide through Yahoo's OAuth system."
            )
            
            InstructionSection(
                title: "Option 2: App Password",
                icon: "key.fill",
                content: "Alternatively, generate an app-specific password in your Yahoo account settings and enter it here."
            )
            
            Divider()
                .padding(.vertical, 8)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Creating a Yahoo App Password:")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    InstructionStep(number: 1, text: "Go to Yahoo Account Settings → Security")
                    InstructionStep(number: 2, text: "Select 'Generate app password'")
                    InstructionStep(number: 3, text: "Choose 'Other app' and name it 'InboxGlide'")
                    InstructionStep(number: 4, text: "Copy the generated password and paste it here")
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
        }
    }
}

struct FastmailInstructions: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            InstructionSection(
                title: "Step 1: Generate App Password",
                icon: "key.fill",
                content: "Open Fastmail security settings and create an app password for InboxGlide."
            )
            
            InstructionSection(
                title: "Step 2: Connect in InboxGlide",
                icon: "envelope.badge",
                content: "Click 'Connect Fastmail' in Settings > Accounts, then enter your email address and app password."
            )
            
            Divider()
                .padding(.vertical, 8)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Creating a Fastmail App Password")
                    .font(.headline)
                
                VStack(alignment: .leading, spacing: 8) {
                    InstructionStep(number: 1, text: "Log into Fastmail web interface")
                    InstructionStep(number: 2, text: "Go to Settings → Privacy & Security → App Passwords")
                    InstructionStep(number: 3, text: "Click 'New App Password'")
                    InstructionStep(number: 4, text: "Name it 'InboxGlide' and grant Mail access")
                    InstructionStep(number: 5, text: "Copy the password and use it here")
                }
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(8)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Server Settings")
                        .font(.headline)
                }
                
                Text("IMAP: imap.fastmail.com:993 (SSL), SMTP: smtp.fastmail.com:465 or 587 (TLS).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.blue.opacity(0.1))
            .cornerRadius(8)
        }
    }
}

struct InstructionSection: View {
    let title: String
    let icon: String
    let content: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(content)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct InstructionStep: View {
    let number: Int
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number).")
                .font(.subheadline.bold())
                .foregroundStyle(.blue)
                .frame(width: 20, alignment: .leading)
            
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
