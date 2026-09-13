# Contributing

Thanks for your interest in SoundIn. This is a small personal project, but contributions are welcome.

## Workflow

1. Fork and create a branch off `main`:
   - `feat/xxx` for new features
   - `fix/xxx` for bug fixes
2. Keep changes focused; one logical change per PR.
3. Open a pull request against `main` with a short description of the change and the motivation.

## Development

- Requires macOS 15+ and the Swift 6.0 toolchain.
- Build with `./build-app.sh`, then run `.build-cache/app/SoundIn.app`.
- By default the build uses ad-hoc signing (`SIGN_IDENTITY=-`). To keep a stable code signature across builds, set your own identity via the `SIGN_IDENTITY` environment variable.

## Code conventions

- Swift 6, SwiftUI. Prefer clarity over cleverness.
- Do **not** hardcode API keys, tokens, personal endpoints, or any credentials. All secrets come from user configuration at runtime.
- Keep the app local-first: no telemetry, no network calls except to the endpoint the user explicitly configures.
- UI changes should be discussed with a mockup first when non-trivial.

## Reporting issues

Use GitHub Issues for bugs and feature requests. For security-sensitive matters, follow [SECURITY.md](SECURITY.md) instead of public issues.
