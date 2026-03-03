# Feature: Reply Back with AI + Correct Provider Integration (Gmail Phase 1)

## Overview

Implement end-to-end reply sending from the existing composer flow, with provider-aware routing based on the message account. In this phase, in-app send is implemented for Gmail only, while AI reply generation remains optional (users can send AI-generated or manually edited text). After successful send, keep the original message in inbox and mark it read.

## Success Criteria

- [ ] All tasks complete
- [ ] All tests passing (if/when tests exist)
- [ ] Build succeeds
- [ ] No blockers

## Tasks

### Task-001: Define Reply Send Contract in App Layer

**Priority**: High  
**Estimated Iterations**: 1-2

**Acceptance Criteria**:

- [ ] Add a focused app-layer reply send contract (payload/model) with required fields: account resolution, recipient, subject, body, and provider threading identifiers where available.
- [ ] Add a single MailStore entry point for sending a reply to a specific message ID.
- [ ] Ensure the contract can be used by both `.reply` and `.aiReply` composer modes.
- [ ] Keep changes minimal and aligned with existing MailStore/service architecture.

**Verification**:

```bash
# Build succeeds after app-layer send contract is added
xcodebuild -project InboxGlide.xcodeproj -scheme InboxGlide -configuration Debug -destination "platform=macOS" build
```

### Task-002: Implement Gmail Provider Reply Send

**Priority**: High  
**Estimated Iterations**: 2-3

**Acceptance Criteria**:

- [ ] Add Gmail send API support in service/auth layers (reuse existing OAuth token flow in `GmailAuthStore`).
- [ ] Construct and send RFC822-compatible reply content for Gmail API, including reply subject behavior and threading metadata (`threadId` and message headers when available).
- [ ] Handle provider/API errors with user-facing, actionable error messages.
- [ ] Keep sensitive data handling consistent with current app patterns.

**Verification**:

```bash
# Build succeeds with Gmail send integration
xcodebuild -project InboxGlide.xcodeproj -scheme InboxGlide -configuration Debug -destination "platform=macOS" build
```

### Task-003: Wire Composer Send Button to Provider-Aware Send Path

**Priority**: High  
**Estimated Iterations**: 2-3

**Acceptance Criteria**:

- [ ] Replace the current stub send behavior in `ReplyComposerView` with a call to MailStore send entry point.
- [ ] Keep AI generation optional: users can send manually typed or AI-generated content.
- [ ] Add send-in-progress state to prevent duplicate sends.
- [ ] On successful send: keep message in inbox and set `isRead = true`.
- [ ] Preserve existing composer presentation flow from deck/action pad.

**Verification**:

- Manual test: Open an email from a Gmail account, use AI Reply or Reply, send successfully, verify composer dismisses and original message remains visible but marked read.
- Automated/build: `xcodebuild -project InboxGlide.xcodeproj -scheme InboxGlide -configuration Debug -destination "platform=macOS" build`

### Task-004: Provider Fallback Behavior for Non-Gmail Accounts

**Priority**: Medium  
**Estimated Iterations**: 1-2

**Acceptance Criteria**:

- [ ] For Yahoo/Fastmail in this phase, do not attempt SMTP/JMAP send.
- [ ] Show clear in-app error/notice that reply send is not yet supported for this provider.
- [ ] Ensure non-Gmail failure path does not mutate message state (`isRead`, archive/delete) unexpectedly.
- [ ] Logging is added in parity with existing provider operations.

**Verification**:

- Manual test: Open Yahoo/Fastmail message, attempt send, verify user sees non-support message and no destructive local state change occurs.
- Automated/build: `xcodebuild -project InboxGlide.xcodeproj -scheme InboxGlide -configuration Debug -destination "platform=macOS" build`

### Task-005: Validation, Regression Checks, and Docs

**Priority**: Medium  
**Estimated Iterations**: 1-2

**Acceptance Criteria**:

- [ ] Run build validation on modified code paths.
- [ ] Verify existing archive/delete provider actions still compile and behavior remains unchanged.
- [ ] Update README/notes to reflect AI reply send status (Gmail supported in-app; IMAP providers pending).
- [ ] Ensure no new warnings/errors introduced in changed files.

**Verification**:

```bash
# Project build validation
xcodebuild -project InboxGlide.xcodeproj -scheme InboxGlide -configuration Debug -destination "platform=macOS" build
```

## Technical Constraints

- Language: Swift
- Framework: SwiftUI (macOS app target)
- Platform: macOS 14+
- Provider integrations currently in codebase:
  - Gmail via OAuth + Gmail REST API
  - Yahoo via IMAP (app password)
  - Fastmail via IMAP (app password)
- Testing: No dedicated test target currently visible; rely on build + manual verification for this feature.
- Style: Match existing service/store layering and current logging/error-alert patterns.

## Architecture Notes

- Keep `ReplyComposerView` thin; route send orchestration through `MailStore`.
- Reuse account lookup pattern already used by archive/delete provider sync methods.
- Implement Gmail reply send in service/auth layers (parallel to existing trash/archive flow).
- Data flow:
  1. User opens composer (`.reply` / `.aiReply`)
  2. Optional AI text generation populates editor
  3. User taps Send
  4. Composer calls MailStore send entry
  5. MailStore resolves account/provider and dispatches provider send
  6. On success, local message marked read (not archived)

## Out of Scope

- SMTP send implementation for Yahoo/Fastmail
- JMAP-based Fastmail send support
- Multi-recipient compose (CC/BCC), attachments, rich compose toolbar
- Full thread view and conversation history UI
- Replacing AI stub with cloud model integration
