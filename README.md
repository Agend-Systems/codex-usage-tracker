# Codex Usage Tracker for macOS

<p align="center">
  <img src="Codex%20Usage/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Codex Usage Tracker icon">
</p>

<p align="center">
  <a href="https://github.com/Agend-Systems/codex-usage-tracker/releases/latest"><img src="https://img.shields.io/github/v/release/Agend-Systems/codex-usage-tracker?label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14 or newer">
  <img src="https://img.shields.io/badge/Swift-5-orange?logo=swift" alt="Swift 5">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

Codex Usage Tracker is a free, open-source macOS menu bar app for monitoring **OpenAI Codex usage limits, remaining usage, reset times, and token activity**. Check your session and weekly usage, switch between Codex account profiles, and receive usage notifications without leaving the menu bar.

Built with SwiftUI for macOS 14 Sonoma and newer, the app is distributed as a signed and notarized download or a Homebrew cask. It reads account and usage information through the locally installed Codex CLI's documented app-server protocol. Authentication remains managed by Codex: the tracker never reads, copies, or stores your authentication tokens.

**[Website](https://agend-systems.github.io/codex-usage-tracker/)** · **[Install with Homebrew](#homebrew)** · **[Download the latest release](https://github.com/Agend-Systems/codex-usage-tracker/releases/latest)** · **[Frequently asked questions](#frequently-asked-questions)** · **[Privacy and security](SECURITY.md)**

Codex Usage Tracker is independent software and is not affiliated with or endorsed by OpenAI.

## Screenshots

<p align="center">
  <img src="docs/screenshots/popover.png" width="31%" alt="Codex Usage menu-bar panel showing session usage and token activity">
  &nbsp;
  <img src="docs/screenshots/settings.png" width="64%" alt="Codex Usage account settings with multiple-profile support">
</p>

## Highlights

- Live Codex session and weekly rolling-window usage, reset times, and plan information
- Account token activity with a 14-day chart, lifetime total, peak day, streak, and longest turn
- Multiple Codex account profiles through separate `CODEX_HOME` directories
- Four compact menu-bar styles, including used or remaining percentage
- Local 90-day usage history with CSV export
- Configurable warning and critical notifications
- Credit balance and earned rate-limit reset support when the account provides them
- Per-profile `codex-<name>` terminal launchers
- OpenAI service-status indicator and launch-at-login support
- No analytics, credential extraction, private API calls, or cloud sync

## Requirements

- macOS 14 Sonoma or newer
- A recent [Codex CLI](https://developers.openai.com/codex/cli/) installation
- A ChatGPT account signed in through Codex

The app looks for `codex` in the process `PATH`, Homebrew locations, `~/.local/bin`, `~/.npm-global/bin`, and the Codex macOS app bundle.

## Install Codex Usage Tracker

### Homebrew

Install Codex Usage from the Agend Systems tap:

```sh
brew tap Agend-Systems/tap
brew install --cask Agend-Systems/tap/codex-usage
```

Install future releases with:

```sh
brew update
brew upgrade --cask codex-usage
```

### Manual installation

Download `Codex.Usage.app.zip` and its checksum from the latest [GitHub Release](https://github.com/Agend-Systems/codex-usage-tracker/releases/latest). Verify the download, then unzip the app and move it to Applications:

```sh
shasum -a 256 "Codex.Usage.app.zip"
# Compare this output with Codex.Usage.app.zip.sha256 from the same release.
unzip "Codex.Usage.app.zip"
mv "Codex Usage.app" /Applications/
```

Releases from version 0.1.3 are Developer ID signed and notarized by Apple, so they open normally after download. For version 0.1.2 and earlier, Control-click **Codex Usage.app**, choose **Open**, then confirm the macOS prompt on first launch.

## Frequently asked questions

### How do I check my OpenAI Codex usage limits on a Mac?

Install Codex Usage Tracker, make sure you are signed in to the Codex CLI with your ChatGPT account, and open **Codex Usage.app**. Click its menu bar item to see the usage windows, percentages, and reset times reported by Codex. You can display either used or remaining usage in the menu bar.

### Does it show five-hour and weekly Codex limits?

The tracker displays the rolling usage windows returned by Codex, including five-hour and weekly windows when they are provided for your account. Window lengths, limits, and reset times come from Codex rather than a fixed allowance built into the tracker. Some fields may be unavailable depending on your account and Codex CLI version.

### Can I monitor multiple Codex accounts?

Yes. Add profiles in **Settings → Accounts**, with each profile pointing to a separate `CODEX_HOME` directory. Each directory uses its own Codex-managed sign-in. The tracker also supports per-profile terminal launchers named `codex-<name>`.

### Does it track token activity or OpenAI API billing?

It shows account token activity returned by Codex, including a chart of up to 14 days and lifetime totals when available. It also keeps up to 90 days of local rate-limit history that you can export as CSV. It is a Codex account usage monitor, not an OpenAI API billing dashboard or a per-project cost calculator.

### Does it read my credentials or send analytics?

No. The tracker does not read passwords, API keys, authentication tokens, or Codex credential files, and it includes no analytics or telemetry. It communicates with a local Codex subprocess, which manages authentication and account requests. The tracker's only direct network request is to the public OpenAI service-status endpoint.

Account details and usage snapshots are cached locally. You can remove cached data in **Settings → About → Clear cached data**. See [Privacy and security](SECURITY.md) for the full data-handling details.

### Is Codex Usage Tracker free, and does it work on Windows or Linux?

The tracker is free and open source under the [MIT license](LICENSE). It requires macOS 14 Sonoma or newer; Windows and Linux are not supported. Your Codex account's own access requirements and usage limits still apply.

### Is this an official OpenAI app?

No. Codex Usage Tracker is an independent project maintained by [Agend Systems](https://github.com/Agend-Systems), built on the documented Codex app-server interface. It is not affiliated with or endorsed by OpenAI.

## Build and run

```sh
git clone https://github.com/Agend-Systems/codex-usage-tracker.git
cd codex-usage-tracker
open "Codex Usage.xcodeproj"
```

Select the **Codex Usage** scheme and run it on **My Mac**. Command-line builds do not require signing:

```sh
xcodebuild \
  -project "Codex Usage.xcodeproj" \
  -scheme "Codex Usage" \
  -configuration Debug \
  -derivedDataPath /tmp/codex-usage-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

On first launch, Codex Usage Tracker starts `codex app-server --stdio` and uses the account already signed in for the selected Codex home. Add more profiles in Settings → Accounts.

## Architecture and privacy

The app sends the documented `initialize`, `account/read`, `account/rateLimits/read`, and `account/usage/read` app-server messages over a local subprocess pipe. Sparse `account/rateLimits/updated` notifications are merged into the latest snapshot. Reset credits use `account/rateLimitResetCredit/consume` only after explicit confirmation.

Profile settings, cached snapshots, and history are stored in the app's local preferences. Authentication stays entirely inside Codex. The only direct network request made by this app is the public OpenAI status endpoint.

See the [Codex app-server documentation](https://developers.openai.com/codex/app-server/) for the protocol contract.

## Support and contributing

- [Report a bug or request a feature](https://github.com/Agend-Systems/codex-usage-tracker/issues)
- [Read the changelog](CHANGELOG.md)
- [Contribute to Codex Usage Tracker](CONTRIBUTING.md)
- [Report a security vulnerability privately](SECURITY.md#reporting-a-vulnerability)

## Attribution

This project is a Codex-focused derivative of Hamed Elfayome's MIT-licensed [Claude Usage Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker). The original license notice is preserved in [LICENSE](LICENSE). Codex Usage Tracker is independent software and is not affiliated with or endorsed by OpenAI.

## License

MIT. See [LICENSE](LICENSE).
