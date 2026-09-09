# Security

## Data handling

Codex Usage Tracker does not request or store passwords, API keys, OAuth tokens, session cookies, or Codex credential files. Account access remains inside the installed Codex CLI. The app communicates with `codex app-server --stdio` over local pipes and stores only profile labels, optional `CODEX_HOME` paths, usage snapshots, preferences, and 90 days of usage history in local app preferences.

The app does not include analytics or telemetry. Its only direct network call is to the public OpenAI service-status endpoint.

## Reporting a vulnerability

Report security issues privately to the repository owner. Include the affected version, reproduction steps, impact, and any suggested mitigation. Do not include real credentials or private account data.

Only run builds from a repository and commit you trust. Unsigned local builds are intended for development; distributed releases should be Developer ID signed and notarized.
