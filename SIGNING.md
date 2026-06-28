# Drott — Code Signing & Notarization Setup

## Status
- [x] Apple Developer account created (Team ID: 3FY4D2C459)
- [x] Developer ID Application certificate installed in login Keychain
- [ ] App Store Connect API key for notarization (awaiting 24-48h account activation)
- [ ] Wire signing + notarization into package.json
- [ ] Test signed + notarized build

---

## Step 1 — Get the notarization API key (when account unlocks)

1. Go to developer.apple.com → Certificates, IDs & Profiles → **Keys** → **+**
2. Name: "Drott Notarization", enable **Developer ID**
3. Download the `.p8` file → save to `Documents/Important documents/`
4. Note the **Key ID** shown on the confirmation page
5. Team ID is already known: **3FY4D2C459**

## Step 2 — Store credentials (tell Claude to do this)

```bash
xcrun notarytool store-credentials "drott-notarize" \
  --key "/Users/emil/Documents/important documents/AuthKey_KEYID.p8" \
  --key-id YOUR_KEY_ID \
  --issuer 3FY4D2C459
```

## Step 3 — Update package.json (Claude will do this)

Add to the `"mac"` section in `build`:

```json
"mac": {
  "target": [{ "target": "dmg", "arch": ["arm64", "x64"] }],
  "category": "public.app-category.games",
  "identity": "Developer ID Application: EMIL DANIELSEN (3FY4D2C459)",
  "notarize": {
    "teamId": "3FY4D2C459"
  }
}
```

## Step 4 — Test build

```bash
cd drott-electron
npm run dist
```

The DMG should build, sign, and notarize automatically. When done, right-click the
app inside the DMG → Get Info → should show "Developer ID Application: Emil Danielsen".
