# Releasing

Pushing a tag that starts with `v` publishes an unsigned GitHub Release. The workflow builds and tests the app, then uploads `Codex Usage.app.zip` and `Codex Usage.app.zip.sha256`.

Unsigned releases require users to Control-click the app and choose **Open** the first time. Add Developer ID signing and notarization before representing releases as fully trusted macOS distributions.

## One-time setup

1. Keep the registered bundle identifier aligned with `com.agend.CodexUsageTracker`.
2. Select the release team and Developer ID Application certificate in Xcode.
3. Add repository secrets for signing and notarization when signed releases are required.
4. Decide on a trusted update channel before adding an updater dependency or feed URL.

## Release checklist

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project.
2. Move the relevant entries in `CHANGELOG.md` from Unreleased to a dated release.
3. Run the Debug and Release builds plus tests.
4. Push an annotated version tag such as `v0.1.0`.
5. Confirm the GitHub Actions workflow publishes `Codex Usage.app.zip` and `Codex Usage.app.zip.sha256`.
6. Verify the app on a clean macOS account with a current Codex CLI.
7. When signing is configured, Developer ID sign, notarize, and staple the exported app or disk image before publishing.

Do not reuse signing, update-feed, Homebrew, or release credentials from the upstream Claude Usage Tracker project.
