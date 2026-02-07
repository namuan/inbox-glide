# InboxGlide Product Specification

**Product Name:** InboxGlide  
**Tagline:** Glide Through Emails: Fun, Fast, and Finally Free of Overload  
**Platform:** macOS Desktop (Mac only - no mobile support)  
**Target Audience:** Professionals and power users overwhelmed by email overload

---

## 1. Product Vision

InboxGlide transforms email management from a tedious chore into an effortless, almost enjoyable experience. Instead of clicking through endless lists and menus, users glide through their inbox with intuitive gestures—just like flipping through cards. The goal is simple: make reaching Inbox Zero so fast and satisfying that users actually look forward to cleaning their email.

---

## 2. Core Experience

### 2.1 The Glide Interface

The main interaction happens through a card-based interface where each email appears as a single card:

- **Glide Left** → Delete the email
- **Glide Right** → Star the email for later
- **Glide Up** → Unsubscribe from the sender
- **Glide Down** → Block the sender permanently

Users can perform these actions using:
- Trackpad gestures (two-finger glides)
- Keyboard shortcuts (arrow keys or customizable combos)
- On-screen buttons for mouse users

### 2.2 Customizable Actions

Users aren't locked into default actions. Each of the four glide directions can be reassigned to any of these actions:

- Delete
- Archive
- Mark as Read/Unread
- Star/Unstar
- Mark as Important
- Move to Folder
- Apply Label/Tag
- Unsubscribe (with or without deleting all emails from sender)
- Block Sender
- Snooze (hide for 1 hour, 4 hours, 1 day, or custom time)
- Create Task/Reminder (export to Apple Reminders)
- Skip/Do Nothing
- Reply (open quick composer)

Secondary actions (accessed with Option/Alt key) provide additional flexibility.

---

## 3. Supported Email Providers

InboxGlide works with multiple email services:

### 3.1 Gmail
- Personal Gmail accounts
- Google Workspace (business) accounts
- Full label support
- Threaded conversation view
- Advanced Gmail search

### 3.2 Yahoo Mail
- Personal Yahoo Mail accounts
- Folder support
- Yahoo's spam filtering integration

### 3.3 Fastmail
- Full Fastmail account support
- Fastmail's unique features (tags, aliases)

### 3.4 Multiple Accounts
- Connect unlimited email accounts (on paid plans)
- Switch between accounts instantly
- Optional unified inbox view showing all accounts together
- Color-coded account indicators

---

## 4. Key Features

### 4.1 AI-Powered Quick Reply

When users need to respond to an email quickly:

- Tap "AI Reply" or use keyboard shortcut
- Jot down a quick note about what they want to say
- AI generates a polished, contextually appropriate reply
- User reviews and edits in a simple block-based editor before sending

**Privacy Promise:** Any personally identifiable information (names, emails, addresses, phone numbers) is stripped locally on the user's Mac before being sent to the AI service. Users can also choose to use a local AI model that works entirely offline, or opt-out of AI features completely.

### 4.2 Daily Reminders

Optional scheduled notifications to maintain inbox hygiene:
- User picks their preferred time (default: 9:00 AM)
- Smart notifications: "You have 23 emails waiting. Ready to glide through them?"
- One-tap to open app, snooze, or dismiss
- Disabled by default—users must opt-in

### 4.3 Smart Categorization (Optional)

On-device AI suggests categories for incoming emails:
- Work, Personal, Promotions, Updates, Forums, Social
- No cloud processing—all analysis happens locally
- Helps users prioritize which emails to glide through first

---

## 5. Security & Privacy

### 5.1 Zero-Knowledge Architecture

- **No email content stored on our servers.** Ever.
- All email data stays on the user's Mac
- Authentication tokens secured in macOS Keychain
- Local database encrypted with industry-standard encryption

### 5.2 Privacy Controls

- **Analytics:** Completely opt-in. Off by default.
- **Crash Reporting:** Opt-in only. No email content included.
- **AI Processing:** Explicit consent required for each feature. Local PII masking mandatory.
- **No third-party tracking** or advertising SDKs

### 5.3 Security Certifications

- Passed CASA Tier 2 security audit (Google-endorsed standard)
- Annual third-party security audits
- TLS 1.3 for all network connections

---

## 6. Offline Capability

InboxGlide works even without internet:

- Last 30 days of emails available offline (configurable)
- Glide actions queue up and sync when connection returns
- Compose drafts offline, send when connected
- Full-text search of cached emails works offline

---

## 7. Subscription Plans

### 7.1 Free Trial
- 7 days full access to all features
- No credit card required to start

### 7.2 Monthly Plan
- $7.99/month
- Unlimited glides
- Unlimited email accounts
- Unlimited AI replies
- Priority support

### 7.3 Yearly Plan
- $69.99/year (save ~27%, equivalent to 3 months free)
- All Monthly features included

### 7.4 Lifetime Plan (Optional)
- $199 one-time purchase
- All current and future premium features
- No recurring payments

### 7.5 Free Tier Limitations (Post-Trial)
- Limited to 2 email accounts
- 20 AI replies per month
- Basic customization only

---

## 8. User Preferences & Settings

### 8.1 Glide Customization
- Assign any action to any glide direction
- Choose animation styles (or disable animations)
- Require confirmation for destructive actions (delete, block, unsubscribe)

### 8.2 Appearance
- System/Light/Dark mode
- Card density: Compact, Comfortable, or Spacious
- Font size adjustments

### 8.3 Notifications
- Daily reminder scheduling
- Real-time new mail alerts (per account)
- Notification filtering (all mail, important only, or none)

### 8.4 Startup Behavior
- Open main window on launch
- Start hidden in Dock
- Start as menu bar app only

---

## 9. Accessibility

Full support for macOS accessibility features:

- **VoiceOver:** Complete screen reader support with descriptive labels for all glide actions
- **Keyboard-Only Operation:** Every feature accessible without trackpad/mouse
- **Reduced Motion:** Respects system preference, disables animations
- **High Contrast:** Supports macOS Increase Contrast setting
- **Full Keyboard Access:** Tab through all interface elements

---

## 10. User Journey & Use Cases

### 10.1 The Morning Cleanse
User opens InboxGlide with their coffee. 45 new emails overnight. They glide left on newsletters (delete), glide up on marketing emails (unsubscribe), glide right on important work emails (star for later). Inbox Zero achieved in 3 minutes.

### 10.2 The Weekly Maintenance
User has let emails pile up for a week. 200+ emails. They use keyboard shortcuts (arrow keys) to rapidly process in batches. Archive old threads, block persistent spammers, star action items. Unified inbox lets them clean work and personal simultaneously.

### 10.3 The Quick Reply
Urgent email requires response. User hits AI Reply, types "tell them I'll send the report by Friday but need an extension on the presentation," AI generates professional email, user edits lightly, sends. Total time: 90 seconds.

### 10.4 The Offline Commute
User reviews and organizes emails on a flight with no WiFi. Actions queue up. When they land and connect, everything syncs automatically.

---

## 11. Success Metrics

From the user's perspective, InboxGlide succeeds when:

- Users reach Inbox Zero daily (or their chosen baseline)
- Email processing time drops by 50%+ compared to traditional clients
- Users report lower email-related stress
- Users actually *open* the app voluntarily (not just out of obligation)

---

## 12. Future Possibilities (Post-Launch)

Not required for v1, but potential directions:

- **Shortcuts App Integration:** Automate glide actions with macOS Shortcuts
- **Menu Bar Mini-Mode:** Quick glance at email count without opening full window
- **Team/Shared Inboxes:** Collaborative email management for small teams
- **Calendar Integration:** Turn emails into events automatically
- **Spotlight Search:** Find emails from macOS Spotlight

---

## 13. Brand Voice & Messaging

**Tone:** Energetic but professional. Efficient but human. Fun but never silly.

**Key Messages:**
- "Finally, email doesn't suck."
- "Inbox Zero in minutes, not hours."
- "Your emails stay on your Mac. Period."
- "Glide through the noise. Keep what matters."

**Avoid:** Corporate buzzwords, guilt about email backlog, "inbox zero" as a moral imperative.

---

## 14. Compliance & Legal Requirements

- **GDPR/CCPA Compliance:** Users can export all data (JSON) and request complete deletion
- **CAN-SPAM:** Automated unsubscribe features comply with anti-spam laws
- **App Store Guidelines:** All in-app purchases through Apple, clear privacy disclosures
- **OAuth Compliance:** Follows Google, Yahoo, and Fastmail API policies

---

**Document Version:** 1.0  
**Product:** InboxGlide  
**Tagline:** Glide Through Emails: Fun, Fast, and Finally Free of Overload  
**Platform:** macOS Desktop Only  
**Last Updated:** 2025-03-10