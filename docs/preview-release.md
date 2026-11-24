# Personal iPhone Preview

This branch builds Benjamin's personal Z-Sync Preview, separate from the upstream app.

- Bundle: `com.benjaminlevin.zsync.preview`
- App Store Connect app: `6834716453`
- Last installed baseline: 1.6 (9), based on `ce78776` plus personal Preview changes.
- Candidate: 1.6 (10), browser login persistence.
- Build host: `mbp`; working directory `~/ci/zsync-login-repair/source`.

The Preview uses standard preferences and Application Support, matching build 9. Its keychain identity and stable per-container WebKit identifiers must remain unchanged. The Share extension and managed default-browser entitlement are not in this build. The guest browser remains available.

Browser session cookies are checkpointed to device-only Keychain records, separately for the default store and each workspace container. Native persistent cookies retain their own expiration. Restoration completes before initial navigation; cookie deletions replace the checkpoint. Clear Website Data invalidates checkpoints before clearing WebKit and resumes an interrupted clear on launch. No cookie values are logged or checked into the repository.

## Validation and shipping

Generate the project with `xcodegen generate` from `ios`. Run the test suite on a clean simulator. New regression tests cover container lifetime, cold restoration, security attributes, isolation, logout, clearing, newer-cookie precedence, and rejection of stale Keychain records after clearing.

The reusable workflow is the Shared General vault's `Apple App Development/Headless TestFlight Builds.md`. `ios/scripts/ship-preview.sh` adapts it for this app. It uses the existing build keychain and App Store Connect API key on the build Mac; credentials and `ios/Config/Team.local.xcconfig` are not committed. Check the current App Store Connect build number before running the script with the next unused number. Verify processing and tester availability after upload.
