# Contributing

Issues and pull requests are welcome. For sensitive reports, follow
[SECURITY.md](SECURITY.md) instead of opening an issue.

## Development requirements

- Flutter 3.44 or newer and Dart 3.12 or newer
- Java 17 and Android SDK 36
- Xcode 16 or newer for iOS work
- A physical device for camera/session verification

## Before opening a pull request

```bash
tool/verify.sh
tool/verify.sh --ios
flutter pub publish --dry-run
```

Native channel changes must be reflected in Dart, Kotlin, Swift and the contract
checker. Add tests for behavior changes and never commit credentials, user media,
`.env` files, generated Flutter metadata, or Xcode user state.

By participating, you agree to follow [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
