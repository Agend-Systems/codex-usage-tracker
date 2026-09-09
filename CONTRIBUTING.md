# Contributing

Codex Usage Tracker is a SwiftUI macOS application. Contributions should preserve its narrow privacy model: use the documented local Codex app-server interface, do not read authentication files or keychain entries, and do not add analytics.

## Development

1. Install Xcode and a recent Codex CLI.
2. Open `Codex Usage.xcodeproj` and select the **Codex Usage** scheme.
3. Build for **My Mac**.
4. Run the unit tests before submitting changes.

```sh
xcodebuild \
  -project "Codex Usage.xcodeproj" \
  -scheme "Codex Usage" \
  -configuration Debug \
  -derivedDataPath /tmp/codex-usage-derived \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Keep protocol models tolerant of optional fields and unknown account types. UI changes should work in light and dark appearances and remain readable at menu-bar scale.
