# Personal iPhone Preview

This branch builds Benjamin's personal Z-Sync Preview, separate from the upstream app.

- Bundle: `com.benjaminlevin.zsync.preview`
- App Store Connect app: `6834716453`
- Last installed baseline: 1.6 (9), based on `ce78776` plus personal Preview changes.
- Shipped: 1.6 (11), HTTP/HTTPS registration plus browser login persistence, November 24, 2026.
- Source commit: `71f3408` on `fix/ios-login-persistence`.
- Public TestFlight: https://testflight.apple.com/join/H3U7JJUf
- Build host: `mbp`; working directory `~/ci/zsync-login-repair/source`.

The Preview uses standard preferences and Application Support, matching build 9. Its keychain identity and stable per-container WebKit identifiers must remain unchanged. The Share extension and managed default-browser entitlement are not in this build. The guest browser remains available.

Browser session cookies are checkpointed to device-only Keychain records, separately for the default store and each workspace container. Native persistent cookies retain their own expiration. Restoration completes before initial navigation; cookie deletions replace the checkpoint. Clear Website Data invalidates checkpoints before clearing WebKit and resumes an interrupted clear on launch. No cookie values are logged or checked into the repository.

## Validation and shipping

### Pending browser entitlement

Build 11 includes HTTP and HTTPS URL registration for the default-browser entitlement application. Build 10 does not declare those schemes. The managed browser entitlement remains absent until Apple approval and a matching provisioning profile; default-browser selection and website passkeys remain unavailable.

The source uses WKWebView, provides URL/search entry without Mozilla sign-in, routes incoming web URLs into the browser, makes no associated-domain Universal Link claims, and contains none of the privacy usage keys prohibited by Apple's default-browser checklist. These source checks do not establish Apple approval or on-device passkey functionality; both remain pending.

### Build 11

App Store Connect build ID: `bd4196f4-9dfc-416b-b1af-911d657999f0`. Processing is `VALID`, internal state is `IN_BETA_TESTING`, and external state is `BETA_APPROVED`. Build 11 is assigned to both the internal **Z-Sync Preview** group and the external **Apple Entitlement Review** group. The existing public link is enabled with a 10-tester limit.

The archive and upload succeeded on `mbp`; artifacts and logs are in `~/ci/zsync-login-repair/release-11/`. Upload completed November 24, 2026 at 17:33 EST. The compiled app's bundle identifier, version/build, HTTP/HTTPS schemes, and absence of prohibited privacy usage keys were verified. This release only changes URL registration and the build number from build 10; the 523-test application suite passed for build 10. No new full-suite run was needed for these configuration changes.

### Build 10

Build 10 completed Apple processing (`VALID`) and is `IN_BETA_TESTING` in the existing internal **Z-Sync Preview** group. App Store Connect build ID: `9c9c34b8-ff2f-4855-a438-6f301b2e5b4f`. It was also approved for the external group on November 24, 2026, before build 11 superseded it.

The final signed simulator suite passed **523 tests with zero failures**. Results are on `mbp` at `~/ci/zsync-login-repair/signed-suite.xcresult`; the archive and upload logs are in `~/ci/zsync-login-repair/release-10/`. The uploaded archive's bundle identifier, version, build number, and signing entitlements were verified. Upload succeeded on November 24, 2026 at 17:11 EST.

Generate the project with `xcodegen generate` from `ios`. Run the test suite on a clean simulator. New regression tests cover container lifetime, cold restoration, security attributes, isolation, logout, clearing, newer-cookie precedence, and rejection of stale Keychain records after clearing.

The reusable workflow is the Shared General vault's `Apple App Development/Headless TestFlight Builds.md`. `ios/scripts/ship-preview.sh` adapts it for this app. It uses the existing build keychain and App Store Connect API key on the build Mac; credentials and `ios/Config/Team.local.xcconfig` are not committed. Check the current App Store Connect build number before running the script with the next unused number. Verify processing and tester availability after upload.
