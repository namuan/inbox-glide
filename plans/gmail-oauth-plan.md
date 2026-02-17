Below is a **clear, implementation-ready PLAN** to add **Gmail OAuth 2.0 authentication** to a **Swift + SwiftUI macOS application**.
This is structured as **phases**, so you can execute it incrementally and keep the app stable at every step.

---

## Phase 0 — Architecture Decisions (before writing code)

**Decide once, early:**

* OAuth flow: **Authorization Code + PKCE**
* Redirect handling: **Custom URL scheme**
* Token storage: **macOS Keychain**
* API access style: **Direct REST calls** (not the full Google SDK)
* UI framework: **SwiftUI**, lifecycle via `@main App`

Primary external systems:

* **Google OAuth 2.0**
* **Gmail REST API**

---

## Phase 1 — Google Cloud Configuration (one-time setup)

**Deliverable:** OAuth credentials that your app can use.

1. Create a Google Cloud project
2. Enable **Gmail API**
3. Configure OAuth consent screen

   * App type: *External*
   * Add scopes (start minimal):

     * `gmail.readonly`
4. Create OAuth Client ID

   * Type: **Desktop App**
5. Save:

   * `client_id`

✅ No client secret needed
✅ PKCE required

---

## Phase 2 — macOS App Configuration

**Deliverable:** App can receive OAuth redirects.

### 2.1 Register custom URL scheme

Example:

```
mygmailapp://oauth/callback
```

Add to `Info.plist`:

* `CFBundleURLTypes`
* URL scheme matches the redirect URI

### 2.2 SwiftUI lifecycle integration

* App entry point: `@main struct MyApp: App`
* Redirect handling will be routed through:

  * `NSApplicationDelegateAdaptor`

---

## Phase 3 — OAuth Service Layer (Core Logic)

**Deliverable:** A reusable authentication engine (no UI).

Create a dedicated service:

```
OAuthService
```

Responsibilities:

* Generate PKCE values
* Build authorization URL
* Open system browser
* Exchange auth code for tokens
* Refresh access tokens

Key functions:

* `startAuthorization()`
* `handleRedirect(url:)`
* `exchangeCodeForToken(code:)`
* `refreshAccessToken()`

**Important:**
This layer must have **zero SwiftUI dependencies**.

---

## Phase 4 — Redirect Handling Bridge

**Deliverable:** OAuth redirect reaches SwiftUI state.

1. Implement `NSApplicationDelegate`
2. Capture incoming URLs
3. Forward URL to `OAuthService`
4. Publish auth result via:

   * `@Published` properties
   * or async/await continuation

This keeps OAuth logic **platform-native** while UI remains SwiftUI-pure.

---

## Phase 5 — Token Persistence & Security

**Deliverable:** Secure, silent authentication after first login.

### 5.1 Keychain storage

Store:

* `refresh_token` (long-term)
* `access_token` (optional)
* `expiration_date`

Never store tokens in:

* `UserDefaults`
* Files
* Plists

### 5.2 Token lifecycle logic

* On app launch:

  * Check Keychain
  * Refresh access token if needed
* On logout:

  * Delete Keychain entries

---

## Phase 6 — SwiftUI Authentication UI

**Deliverable:** User-visible sign-in flow.

### 6.1 Auth ViewModel

```
AuthViewModel : ObservableObject
```

State:

* `isAuthenticated`
* `isLoading`
* `authError`

Methods:

* `signIn()`
* `signOut()`

### 6.2 Views

* **Signed-out view**

  * “Sign in with Google” button
* **Loading view**
* **Signed-in view**

  * Shows Gmail-enabled features

UI only reacts to state — **no OAuth logic inside views**.

---

## Phase 7 — Gmail API Client Layer

**Deliverable:** Clean Gmail access abstraction.

Create:

```
GmailService
```

Responsibilities:

* Build authenticated requests
* Attach access token
* Handle 401 → token refresh → retry

Initial endpoints:

* List messages
* Get message metadata
* (Later) read, label, send

---

## Phase 8 — Error Handling & Edge Cases

**Deliverable:** Production-safe behavior.

Handle:

* User cancels login
* Expired refresh token
* Revoked consent
* Network failures
* Scope changes (force re-auth)

UX rules:

* Never silently fail
* Always allow re-authentication

---

## Phase 9 — Testing & Validation

**Deliverable:** Confidence before shipping.

Test:

* Fresh install → login
* App relaunch → silent auth
* Token expiration
* Logout → re-login
* Multiple Google accounts

Verify:

* Google OAuth policy compliance
* No embedded web views
* Minimal scopes requested

---

## Phase 10 — Future Enhancements (Optional)

* Multiple Gmail accounts
* Background token refresh
* Push notifications (via Gmail watch)
* AppAuth migration if requirements grow

---

## Final System Diagram

```
SwiftUI Views
   ↓
AuthViewModel
   ↓
OAuthService ──── Keychain
   ↓
GmailService ──── Gmail REST API
```

---

If you want next:

* A **file-by-file project structure**
* **PKCE generation code**
* **Keychain helper implementation**
* **SwiftUI sample screens**
* Or a **timeline (1-day / 3-day / 1-week build)**

Tell me how deep you want to go.
