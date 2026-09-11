# Releasing

Every CI run uploads an unsigned app artifact for seven days. After a pull request is merged, the push to `main` runs the same checks and Release build. If the built app's `MARKETING_VERSION` does not already have a GitHub Release, the workflow signs and notarizes the app, creates an annotated `v<MARKETING_VERSION>` tag on that commit, and publishes the release automatically. Releases contain the notarized `Codex.Usage.app.zip` and `Codex.Usage.app.zip.sha256`.

Pushes that keep an already-released `MARKETING_VERSION` still build and test, but do not create a duplicate release. A manually pushed `v*` tag remains a recovery path; it must match the version embedded in the built app.

Pull-request and ordinary CI artifacts are unsigned development builds. The release job refuses to publish a new version when its signing or notarization credentials are unavailable.

## Apple signing setup

The Apple Developer Program Account Holder must create a [**Developer ID Application** certificate](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) for distributing the app outside the Mac App Store. Export the certificate and its private key from Keychain Access as a password-protected PKCS#12 (`.p12`) file. Do not use a Mac App Distribution or Developer ID Installer certificate.

Create an App Store Connect API key that can access the Apple notary service and retain its key ID, issuer ID, and downloaded `.p8` file. Add these repository Actions secrets:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID Application `.p12` file |
| `MACOS_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` file |
| `APPLE_API_KEY_P8_BASE64` | Base64-encoded App Store Connect API `.p8` file |
| `APPLE_API_KEY_ID` | App Store Connect API key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect API issuer ID |

Set secrets through GitHub's repository settings or `gh secret set`; never paste certificate or API-key contents into an issue, pull request, commit, or workflow file. Base64 is only an encoding—the GitHub secret is what protects the value.

The Release configuration already enables the hardened runtime and uses `Codex Usage/CodexUsageTracker.entitlements`. Following [Apple's command-line notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), the workflow imports the certificate and Apple's checksum-pinned Developer ID G2 intermediate into a temporary keychain, signs with a secure timestamp, submits the signed ZIP using `notarytool`, staples the accepted ticket, verifies a freshly extracted copy with `codesign`, `stapler`, and Gatekeeper, and only then creates the tag and GitHub Release. The temporary credential files and keychain are removed even when the job fails.

## Release checklist

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project.
2. Move the relevant entries in `CHANGELOG.md` from Unreleased to a dated release.
3. Run the Debug and Release builds plus tests.
4. Merge the pull request into `main`. The successful workflow creates the annotated version tag and GitHub Release.
5. Confirm the release contains `Codex.Usage.app.zip` and `Codex.Usage.app.zip.sha256`.
6. Update the Homebrew cask to the new version and artifact checksum.
7. Verify the app on a clean macOS account with a current Codex CLI.
8. Confirm the release job passed its signing, notarization, stapling, and Gatekeeper checks.

Do not reuse a released `MARKETING_VERSION`. If a `main` build keeps the same version, its artifact expires after seven days and no tag or release is created.

Do not reuse signing, update-feed, Homebrew, or release credentials from the upstream Claude Usage Tracker project.
