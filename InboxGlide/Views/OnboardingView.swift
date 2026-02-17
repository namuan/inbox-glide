import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var preferences: PreferencesStore
    @EnvironmentObject private var mailStore: MailStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var currentStep = 0
    
    var body: some View {
        VStack(spacing: 0) {
            if currentStep == 0 {
                WelcomeStep(onNext: { currentStep = 1 }, onSkip: skipOnboarding)
            } else if currentStep == 1 {
                AccountSetupGuideView(onComplete: completeOnboarding, onBack: { currentStep = 0 })
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
    
    private func skipOnboarding() {
        preferences.hasCompletedOnboarding = true
        dismiss()
    }
    
    private func completeOnboarding() {
        preferences.hasCompletedOnboarding = true
        dismiss()
    }
}

struct WelcomeStep: View {
    let onNext: () -> Void
    let onSkip: () -> Void
    
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            VStack(spacing: 16) {
                Image(systemName: "envelope.open.fill")
                    .font(.system(size: 80))
                    .foregroundStyle(.blue.gradient)
                
                Text("Welcome to InboxGlide")
                    .font(.system(size: 36, weight: .bold))
                
                Text("Glide Through Emails: Fun, Fast, and Finally Free of Overload")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            VStack(alignment: .leading, spacing: 20) {
                FeatureRow(icon: "hand.draw", title: "Intuitive Gestures", description: "Swipe left to delete, right to star, up to unsubscribe, down to block")
                FeatureRow(icon: "sparkles", title: "AI-Powered Replies", description: "Quick, smart responses with your privacy protected")
                FeatureRow(icon: "lock.shield", title: "Privacy First", description: "Your emails stay on your Mac. Always.")
            }
            .padding(.horizontal, 60)
            
            Spacer()
            
            HStack(spacing: 16) {
                Button("Skip for Now") {
                    onSkip()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Get Started") {
                    onNext()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 40)
        }
        .padding()
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 30)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
