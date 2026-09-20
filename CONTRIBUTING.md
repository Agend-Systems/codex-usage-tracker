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

## Website and documentation

The public landing page lives in `docs/` and uses plain HTML and CSS, with no build dependencies. GitHub Pages should publish the `main` branch's `/docs` directory. The `.nojekyll` file keeps the static files unchanged.

To preview it locally from the repository root:

```sh
python3 -m http.server 8765 --directory docs
```

Open `http://localhost:8765`. Check desktop and narrow-screen layouts, navigation, FAQ disclosures, and download links after changes. Keep the README, website, privacy information, and app behavior consistent. Update the canonical URL, Open Graph URL, structured data, and `docs/sitemap.xml` together if the website address changes.

The sitemap is published at `https://agend-systems.github.io/codex-usage-tracker/sitemap.xml`. Once the site is live, a maintainer can verify this URL-prefix property in Google Search Console and submit the sitemap. A project-level `docs/robots.txt` would not control crawlers: robots rules are read from the host root, `https://agend-systems.github.io/robots.txt`.
