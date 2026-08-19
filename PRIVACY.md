# Privacy integration guide

`decart_vton_flutter` sends live camera video, text prompts and optional garment
images to Decart so the service can return transformed video. The package itself
does not persist media or client tokens, operate analytics, or create user
profiles.

Applications integrating the package must:

1. Explain the processing before requesting camera or photo-library access.
2. Capture only after an explicit user action and stop promptly on background or
   when the user taps stop.
3. Authenticate and rate-limit the backend endpoint that mints client tokens.
4. Use HTTPS, avoid token/media logging and apply appropriate log redaction.
5. Disclose Decart as a service provider and accurately complete Google Play
   Data safety and Apple App Privacy declarations.
6. Review Decart's current privacy policy, API terms, retention practices and
   data-processing agreement, and obtain any consent required by local law.
7. Provide an appropriate deletion/contact route for user privacy requests.

The host application determines its legal basis, audience restrictions,
retention policy and jurisdiction-specific obligations. This guide is technical
integration information, not legal advice.
