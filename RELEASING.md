# Releasing

Release publishing is intentionally disabled until the project has an Apple developer identity.

## One-time setup

1. Keep the registered bundle identifier aligned with `com.agend.CodexUsageTracker`.
2. Select the release team and Developer ID Application certificate in Xcode.
3. Add repository secrets for signing and notarization only if automated releases are required.
4. Decide on a trusted update channel before adding an updater dependency or feed URL.

## Release checklist

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Xcode project.
2. Move the relevant entries in `CHANGELOG.md` from Unreleased to a dated release.
3. Run the Debug and Release builds plus tests.
4. Archive with the **Codex Usage** scheme.
5. Developer ID sign, notarize, and staple the exported app or disk image.
6. Verify the app on a clean macOS account with a current Codex CLI.
7. Publish the artifact and checksums from the project's own repository.

Do not reuse signing, update-feed, Homebrew, or release credentials from the upstream Claude Usage Tracker project.
