# Releasing

Every CI run uploads an unsigned app artifact for seven days. After a pull request is merged, the push to `main` runs the same checks and Release build. If the built app's `MARKETING_VERSION` does not already have a GitHub Release, the workflow creates an annotated `v<MARKETING_VERSION>` tag on that commit and publishes the release automatically. Both contain `Codex Usage.app.zip` and `Codex Usage.app.zip.sha256`.

Pushes that keep an already-released `MARKETING_VERSION` still build and test, but do not create a duplicate release. A manually pushed `v*` tag remains a recovery path; it must match the version embedded in the built app.

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
4. Merge the pull request into `main`. The successful workflow creates the annotated version tag and GitHub Release.
5. Confirm the release contains `Codex Usage.app.zip` and `Codex Usage.app.zip.sha256`.
6. Update the Homebrew cask to the new version and artifact checksum.
7. Verify the app on a clean macOS account with a current Codex CLI.
8. When signing is configured, Developer ID sign, notarize, and staple the exported app or disk image before publishing.

Do not reuse a released `MARKETING_VERSION`. If a `main` build keeps the same version, its artifact expires after seven days and no tag or release is created.

Do not reuse signing, update-feed, Homebrew, or release credentials from the upstream Claude Usage Tracker project.
