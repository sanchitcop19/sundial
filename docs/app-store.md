# Distributing Sundial

Publishing the source on GitHub does not require Apple signing credentials.
The downloadable macOS app has a separate build, signing, and packaging process.
The normal distribution route for this project is a DMG attached to a
[GitHub release](https://github.com/sanchitcop19/sundial/releases).

## Direct-download releases

`release.sh` builds the app, signs it with a Developer ID Application identity,
creates a compressed DMG with an Applications shortcut, submits it for
notarization, and staples the ticket. The script requires:

- A **Developer ID Application** certificate and its private key in the keychain.
- The Swift toolchain and macOS command-line tools used by `build-app.sh`.
- Notary credentials, using either an App Store Connect API key or a stored
  keychain profile.

For API-key authentication, copy `asc.env.example` to the gitignored `asc.env`
and set your key ID, issuer ID, and private-key path. Keep the `.p8` key outside
this repository.

Alternatively, store credentials in the keychain:

```bash
xcrun notarytool store-credentials sundial \
  --apple-id you@example.com --team-id TEAMID
```

The command prompts for the remaining credential. To use another stored profile,
set `NOTARY_PROFILE` when running the release script.

```bash
SUNDIAL_VERSION=0.1.0 ./release.sh
SUNDIAL_VERSION=0.1.0 ./publish.sh
```

`release.sh` writes `dist/Sundial-<version>.dmg`. `publish.sh` needs an `origin`
remote and an authenticated GitHub CLI; it creates a version tag and uploads the
DMG. Check the final artifact and its signing status before publishing. The
release notes should state the minimum macOS version, supported processor
architecture, and whether that specific build is notarized.

`build-app.sh` can also use an Apple Development identity for local builds. That
is not the Developer ID identity required by the notarized release workflow.

### Unnotarized preview downloads

`SUNDIAL_VERSION=0.1.0 ./release.sh --preview` builds a universal app for Apple
silicon and Intel, signs it ad hoc, and writes `dist/Sundial-0.1.0.dmg`. It does
not use Apple credentials, submit to notarization, or replace an installed app.
The script verifies both architectures, the signatures, and the disk image.

Preview signatures do not verify developer identity. Release notes must say
the download is not notarized and explain **System Settings → Privacy & Security
→ Open Anyway** after the first launch attempt, following
[Apple's guidance](https://support.apple.com/en-us/102445). Users may need to
grant permissions again after preview updates.

## Mac App Store packaging

`appstore.sh` is an experimental packaging path. It builds with
`Sundial-sandbox.entitlements`, embeds a provisioning profile, signs an installer
package, and runs App Store Connect validation. It does not upload the package;
it prints a separate upload command after validation.

The script checks for:

- An **Apple Distribution** or **3rd Party Mac Developer Application** identity.
- A **3rd Party Mac Developer Installer** identity.
- A provisioning profile matching the bundle ID, passed through
  `SUNDIAL_PROVISION_PROFILE` or placed at the script's default path.
- An App Store Connect API key, configured using the same environment variables
  as the direct-download workflow.

The sandboxed build needs separate feature testing before distribution. Browser
scripting, Firefox session files, editor project paths, cloud-folder access, and
migration of existing records all interact with permissions or file access
outside the app's container. The entitlement file includes temporary exceptions;
packaging successfully does not establish that these features work in the
sandbox or that a submission will pass App Store review.

## Credentials and local data

Do not commit signing private keys, API keys, passwords, provisioning profiles,
`asc.env`, or activity records. Use environment variables or keychain profiles
for release credentials. Build artifacts belong in `dist/` and GitHub releases,
not in the source history.
