# iOS builds to TestFlight

Xcode Cloud archives the iOS app whenever `main` changes under `ios/`,
`Sources/SundialCore/` or `Package.swift`, and uploads it for internal
TestFlight testing. Every App Store Connect user on the team is in the
internal "Phone" group, which gets every build automatically.

- `ios/ci_scripts/ci_post_clone.sh` generates the Xcode project with XcodeGen,
  since only `project.yml` is committed.
- `ios/ci_scripts/ci_pre_xcodebuild.sh` stamps Xcode Cloud's build number into
  the archive, so each upload is newer than the last.
- `ITSAppUsesNonExemptEncryption = false` skips the export-compliance question,
  so builds go to testers unattended.

## One-time setup

Apple's API cannot create the app record or the Xcode Cloud product, so these
two steps happen once in Xcode on a Mac:

1. `brew install xcodegen && cd ios && xcodegen generate && open SundialMobile.xcodeproj`
2. Integrate > Create Workflow. Accept the defaults. Let Xcode create the App
   Store Connect app record, and grant the Xcode Cloud GitHub app access to
   this repository when asked.

Then `ios/setup-testflight.py` (re-runnable) replaces the default workflow
settings, creates the TestFlight group and starts the first build.
