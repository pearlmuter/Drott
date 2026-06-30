# Drott — Code Signing & Notarization Setup

## Status
- [x] Apple Developer account created (Team ID: 3FY4D2C459)
- [x] Developer ID Application certificate installed in login Keychain
      (`Developer ID Application: EMIL DANIELSEN (3FY4D2C459)`)
- [x] App Store Connect API key for notarization created
- [x] Credentials stored in Keychain + wired into package.json
- [x] Signed + notarized build produced

---

## The notarization API key (App Store Connect, NOT the developer portal)

IMPORTANT: the key is created in **App Store Connect**, not at
developer.apple.com/account/resources/authkeys (that page is only for app *service*
keys — APNs, DeviceCheck, etc. — and has no "Developer ID" option). Path:

1. [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Users and Access**
2. **Integrations** tab → **App Store Connect API** → **Team Keys**
3. First time only: click **Request Access** to enable the API for the account
4. **＋** Generate API Key → name `Drott Notarization`, access role **Developer**
5. **Download the `.p8`** (one-time download) → `Documents/important documents/`
6. Note the **Key ID** (key row) and the **Issuer ID** (UUID above the key list)

Current values (this account):
- Key ID    : `995JHZ4BNF`
- Issuer ID : `9024e1e9-20c0-4eb7-bd4b-e880d112501c`  (a UUID — NOT the Team ID)
- Key file  : `/Users/emil/Documents/important documents/AuthKey_995JHZ4BNF.p8`

## Store credentials in the Keychain (done)

```bash
xcrun notarytool store-credentials "drott-notarize" \
  --key "/Users/emil/Documents/important documents/AuthKey_995JHZ4BNF.p8" \
  --key-id 995JHZ4BNF \
  --issuer 9024e1e9-20c0-4eb7-bd4b-e880d112501c
```

## package.json (done) — `build.mac`

```json
"mac": {
  "icon": "assets/drott.icns",
  "target": [{ "target": "dmg", "arch": ["arm64", "x64"] }],
  "category": "public.app-category.games",
  "identity": "EMIL DANIELSEN (3FY4D2C459)",
  "hardenedRuntime": true,
  "gatekeeperAssess": false
}
```

GOTCHA — do **not** add `"notarize": { "teamId": ... }` when using the API-key env
vars. electron-builder 24 merges that `teamId` into the API-key options, and
@electron/notarize then sees both a password-credential field (`teamId`) and
API-key fields and aborts with *"Cannot use password credentials, API key
credentials and keychain credentials at once."* Omitting the `notarize` key
entirely makes electron-builder take the clean API-key-only path (notarization
still runs because the `APPLE_API_*` env vars are present and `notarize` is not
explicitly `false`). The identity string must also be **without** the
`Developer ID Application:` prefix — just `EMIL DANIELSEN (3FY4D2C459)`.

## Building a signed + notarized DMG

electron-builder reads the API key from three env vars (the `.p8` path has a space,
so quote it):

```bash
cd drott-electron
export APPLE_API_KEY="/Users/emil/Documents/important documents/AuthKey_995JHZ4BNF.p8"
export APPLE_API_KEY_ID="995JHZ4BNF"
export APPLE_API_ISSUER="9024e1e9-20c0-4eb7-bd4b-e880d112501c"
npm run dist -- --mac
```

Notarization waits on Apple's servers (typically 3–15 min). electron-builder
staples the ticket automatically on success.

## Verifying a finished build

```bash
APP=dist/mac-arm64/Drott.app
codesign --verify --deep --strict --verbose=2 "$APP"   # → "valid on disk"
spctl --assess --type execute --verbose=4 "$APP"        # → "accepted / Notarized Developer ID"
xcrun stapler validate "$APP"                            # → "The validate action worked!"
```

All three passing = the app opens on any Mac with no Gatekeeper warning.
