# InboxGlide

InboxGlide is a macOS SwiftUI app prototype for processing email as a card deck: glide (swipe) a message left/right/up/down to apply an action.

![](assets/app.png)

- Card-based inbox with trackpad/mouse drag gestures
- Keyboard glides (arrow keys)
- On-screen action buttons
- Customizable glide mappings (primary + Option/Alt secondary)
- Default primary glide mapping: Left = Delete, Right = Archive, Up = Mark Unread, Down = Skip
- Multi-account + optional unified inbox
- Local encrypted store (AES-GCM; key stored in macOS Keychain)
- AI quick reply drafting (local stub) with local PII scrubbing
- In-app AI/manual reply send status: Gmail, Yahoo, and Fastmail supported
- Email summary with on-device Foundation Models support, local fallback, and advisory spam warnings
- Optional daily reminder notifications (Coming soon...)
- Data export + delete-all
- **Production-ready provider integrations:**
  - Gmail OAuth + inbox sync
  - Yahoo app-password onboarding + IMAP inbox sync
  - Fastmail app-password onboarding + IMAP inbox sync

## Requirements

- macOS 14+
- Xcode 15+ (or newer) with Command Line Tools (`xcodebuild`)

## Install (build + copy to ~/Applications)

From Terminal:

```bash
cd inbox-glide
chmod +x install.command
./install.command
```

Or double-click `inbox-glide/install.command` in Finder (it must be executable).

The script builds a Release app and installs it to `~/Applications/InboxGlide.app`.

## Notes

- Data is stored under `~/Library/Application Support/InboxGlide/` and encrypted at rest.
- Notifications and Reminders require macOS permission prompts when you enable/use them.
- Reply send is provider-scoped and available in-app for Gmail, Yahoo, and Fastmail.
