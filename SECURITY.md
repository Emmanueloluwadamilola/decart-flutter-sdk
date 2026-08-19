# Security policy

## Supported versions

Security fixes are provided for the latest published version of
`decart_vton_flutter`. Upgrade to the newest release before reporting a problem.

## Reporting a vulnerability

Do not open a public issue for a vulnerability, leaked credential, token-endpoint
bypass, or user-media exposure. Use
[GitHub private vulnerability reporting](https://github.com/Emmanueloluwadamilola/decart-flutter-sdk/security/advisories/new).

Include the affected version, platform, reproduction steps and impact. Remove
all client tokens, user images and session identifiers from logs or recordings.
You should receive an acknowledgement within five business days.

## Credential model

Production authentication accepts short-lived client tokens supplied by an
async callback. Permanent Decart credentials belong on an authenticated backend
and must never be committed, embedded in a distributed app, sent to analytics,
or written to logs.

`initializeForDevelopment` is an explicit local-prototyping escape hatch. It
accepts a `dct_` test key only in Flutter debug builds and throws in profile and
release builds. The key remains extractable from the debug binary: never share
that build, use a production key, or treat `.env`/`--dart-define` as encryption.
Rotate any credential immediately if exposure is suspected.
