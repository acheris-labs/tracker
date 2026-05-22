# Distributing Tracker

Tracker has no privileged helper, so it runs fine ad-hoc signed. But for
distribution outside the App Store — so users can open it without Gatekeeper
warnings — it should be **Developer ID signed and notarized**. That requires
Apple Developer Program membership ($99/yr). One membership covers Tracker,
Newt, and anything else under the same Team ID.

## One-time setup

1. **Enroll** in the Apple Developer Program (Individual is fine):
   <https://developer.apple.com/programs/> — $99/yr.
2. **Create a Developer ID Application certificate.** Easiest via
   Xcode ▸ Settings ▸ Accounts ▸ (your team) ▸ Manage Certificates ▸ ＋ ▸
   *Developer ID Application*. It lands in your login keychain.
3. **Confirm the identity:**
   ```
   security find-identity -v -p codesigning
   ```
   Note the full string, e.g.
   `Developer ID Application: Chris Madden (AB12CD34EF)`.
4. **Store notarization credentials** once (uses an app-specific password
   from <https://appleid.apple.com> ▸ Sign-In & Security, or an App Store
   Connect API key):
   ```
   xcrun notarytool store-credentials tracker-notary \
     --apple-id you@example.com --team-id AB12CD34EF --password <app-specific-pw>
   ```

## Build & ship

```
make dmg SIGN_ID="Developer ID Application: Chris Madden (AB12CD34EF)"
```

That re-signs the built `.app` with hardened runtime, notarizes via the
`tracker-notary` profile, staples the ticket, and produces
`build/Tracker.dmg`. Intermediate targets `make sign` / `make notarize` are
available too. Override the notary profile name with `NOTARY_PROFILE=...`.

The `build` target itself is unchanged (xcodebuild, ad-hoc); `sign` re-signs
the product afterward. Tracker is a single executable bundle with no nested
frameworks or helpers, so one `codesign` on the bundle is sufficient.

## CI (not yet wired up)

`.github/workflows/release.yml` currently ships an **ad-hoc** DMG. To make
releases notarized, the Developer ID cert must be exported as a base64 `.p12`
and the notary credentials added as repository secrets, then imported into a
temporary keychain in the workflow before `make dmg`. Add this once the
certificate exists.
