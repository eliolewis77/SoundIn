# Security Policy

## Supported Versions

SoundIn is a personal, single-maintainer project. Security fixes are applied to the latest `main` branch. There are no formal release branches.

## Reporting a Vulnerability

If you discover a security issue, please **do not** open a public GitHub Issue. Instead, report it privately:

- Open a private security advisory on the GitHub repository (if enabled), or
- Contact the maintainer directly via the email listed on their GitHub profile.

Please include:

- A description of the vulnerability and its impact
- Steps to reproduce
- Any relevant logs (with secrets/keys redacted)

You can expect an initial response within a few days. Fixes will be landed on `main` and credited in the release notes unless you prefer to remain anonymous.

## Notes on Data & Keys

- API keys are entered by the user and stored only in the local Keychain / `UserDefaults`. They are never embedded in the source code or shipped with the app.
- The app sends audio only to the endpoint the user explicitly configures. There is no telemetry or third-party analytics.
- If you self-host a transcription endpoint, its security is your responsibility.
- Never paste real API keys or credentials into Issues, PRs, or screenshots.
