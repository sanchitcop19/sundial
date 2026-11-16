# iPhone Live Activity

Sundial's iOS 17+ companion shows the Mac's worked hours, daily target, and time
remaining on the Lock Screen and Dynamic Island. Setup requires a shared
folder; locked-phone updates also require an Apple APNs authentication key.
Physical-device push delivery has not yet been verified end to end.

After you choose **Start break** on the Mac, the Live Activity shows **On a break** and the time remaining.
The compact Dynamic Island uses a cup icon and countdown; the expanded and
Lock Screen views retain the daily work totals. Active breaks use an amber accent
and warm dark background; normal work uses mint. The timer keeps counting down
when you switch apps and normal work progress returns when it ends. Idle time
alone never starts a break.

On macOS 26 or later, **Use Live Activity in menu bar when active** reduces Sundial's
native menu-bar indicator to a small progress ring when the shared folder reports
a registered, unexpired Live Activity. Click the ring to see worked and remaining
hours or restore the Live Activity. The full hours display returns when the
registration disappears or expires, or when this setting or phone sync is turned off.
The native control always remains available.
This follows the iPhone's synced registration; macOS doesn't provide an API to
confirm that the mirrored activity is actually visible. Dismissal may take time
to sync, and activities still waiting for a push token retain the native indicator.

If the Live Activity disappears, choose **Restore Live Activity** from the Mac
menu or Settings. Sundial ends known activities before requesting a replacement.
This uses the existing Apple push key and phone connection; it does not erase
tracked hours. If you stopped the activity on iPhone, start it there to clear its
pause first. Apple acceptance alone does not confirm visible delivery.

## How updates travel

1. The Mac writes `work-progress.json` to **iCloud Drive → Sundial** when iCloud
   Drive is available, and to each selected backup destination, about
   once a minute while totals change and **Sync work progress to iPhone** is
   enabled. Unchanged summaries are refreshed every three minutes, leaving a
   two-minute buffer before the five-minute freshness limit. State, target,
   tracking pause, break start/completion, timezone, and day changes
   can trigger an earlier update.
2. The iPhone reads that summary from the folder chosen in Files. It refreshes
   every 30 seconds while the app is active and when the app opens. Background
   refresh is opportunistic; it cannot guarantee updates while locked.
3. Tapping **Start Live Activity** requests an ActivityKit activity. The phone
   writes its update token, environment, Mac date, and expiry into
   `live-activities/<activity-id>.json` in the same folder.
4. With an imported APNs key, the Mac reads those registrations and sends the
   summary directly to Apple's push service. Apple delivers ActivityKit updates
   while the companion is suspended. Unchanged updates use the same three-minute
   heartbeat, independently for each activity. No hosted Sundial backend is involved.

Apple documents the token, HTTP headers, and payload used in this flow in
[Starting and updating Live Activities with ActivityKit push notifications](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications).

The summary contains the Mac's date and timezone, update timestamp, worked time,
daily target, optional weekly totals and target, tracking category, and pause
state, plus an optional break deadline (and support for paused break remainders
from older Mac versions). It contains no
app names, window titles, URLs, or raw observations.
Existing backup settings still govern the other files in that folder: rules
and, when enabled, raw activity records may be present alongside the summary.

## Build and install the companion

The XcodeGen definition creates `SundialMobile` and the embedded
`SundialLiveActivity` extension. From the repository root:

```bash
cd ios
xcodegen generate
xcodebuild -project SundialMobile.xcodeproj -scheme SundialMobile \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/sundial-mobile-build CODE_SIGNING_ALLOWED=NO build
open SundialMobile.xcodeproj
```

For a physical iPhone, select the connected device in Xcode and run the
`SundialMobile` scheme. Both targets use automatic signing with team
your Apple Team ID; the signed-in Apple Developer account must have access to that
team. Xcode must be able to register the device and create or download profiles
for the app and extension. The app's profile must authorize Push Notifications.
The iPhone must run iOS 17 or later and allow Live Activities for Sundial.

A device build can also be requested from `ios/`:

```bash
xcodebuild -project SundialMobile.xcodeproj -scheme SundialMobile \
  -configuration Debug -destination 'generic/platform=iOS' \
  -allowProvisioningUpdates build
```

The project defaults are:

| Configuration | `aps-environment` | APNs destination |
|---|---|---|
| Debug | `development` | Sandbox |
| Release | `production` | Production |

Use a provisioning profile and APNs key that support the chosen environment.
The main app's bundle ID is `dev.sanchit.sundial.mobile`; its ActivityKit push
topic is `dev.sanchit.sundial.mobile.push-type.liveactivity`. If distributing
under another team, update the team, bundle identifiers, and push topic together.

## Connect the shared folder

1. On the Mac, open Sundial **Settings → iPhone Live Activity** and enable
   **Sync work progress to iPhone**. This creates **iCloud Drive → Sundial**
   when iCloud Drive is available. Check that the status reports the summary
   was saved there.
2. If iCloud Drive is unavailable on the Mac, select another backup destination
   that exposes the same writable folder in iPhone Files.
3. Open Sundial on iPhone and choose the existing `Sundial` folder through
   **Browse → iCloud Drive** in Files, or the selected alternative provider.
   Allow the provider to download `work-progress.json` if necessary.
4. In **Today**, confirm the displayed Mac date, timezone, and updated time.
   Tap **Start Live Activity** once a fresh summary is available.

**Include the raw record** is optional for this feature. The phone needs raw
records only for its separate timeline and review features. Phone sync alone
writes only the work summary to iCloud; raw records are copied there only if
iCloud is separately selected in the Mac's backup settings.

Without a push key, opening Sundial on iPhone refreshes the displayed work
summary and any running Live Activity. Continuous locked-phone updates require
the following APNs setup.

### If the phone is waiting to connect

The phone requests its update token from Apple before the Mac can send pushes.
If Apple has not supplied a token after 20 seconds, the app offers **Restart
Live Activity** to request a new activity. This does not erase tracked hours.
If the token arrives but cannot be saved to the shared folder, **Retry sync**
retries that write without restarting the activity. Check the cloud provider's
availability and that the selected folder is writable.

The Mac's APNs key does not control whether the phone receives its activity
token; it is needed for the later push-delivery step. Connection diagnostics
use the `dev.sanchit.sundial.mobile` logging subsystem and `LiveActivity`
category, without logging token contents.

## Enable updates while iPhone is locked

Obtain an **APNs authentication key** from the Apple Developer account for team
your Apple Team ID, with access to the app's push topic and the intended environment.
Apple supplies a `.p8` private key and a 10-character Key ID; the Team ID is
also required. New keys can be scoped to a topic and environment, so check the
scope before selecting one. See Apple's
[token-based APNs connection guide](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns).

An App Store Connect API key is a different credential even though it also uses
a `.p8` file. Import a key enabled for APNs. Downloading or importing a key file
alone does not prove that Apple will accept it for this app.

1. On the Mac, open **Settings → iPhone Live Activity → Set up updates while
   iPhone is locked**.
2. Enter the **Key ID** and **Team ID**, then choose **Import APNs .p8 key…**.
3. Confirm the status says the key was saved. Sundial stores the private key
   and IDs in this Mac's Keychain; it does not copy them to the sync folder or
   phone. Keep the downloaded original outside the repository and shared folder.
4. Start the Live Activity on iPhone. Leave the Mac awake, running Sundial, and
   connected to the internet. Allow the registration file to reach the Mac.
5. Check Mac Settings for the result of its next push attempt. A successful
   send means Apple accepted the request; confirm the changed values on the
   locked iPhone to verify delivery.

## Freshness and lifetime

- The phone shows the last reported work total and remaining time. It never
  advances either number from elapsed wall-clock time between updates.
- A summary becomes stale after five minutes, or at midnight in the **Mac's
  timezone**, whichever comes first. A phone in another timezone uses that Mac
  date for this progress display.
- If the Mac sleeps, goes offline, or folder/push delivery is delayed, the
  numbers remain visible with **Update delayed · last known totals**. Reopening
  the phone app attempts another folder refresh.
- Each activity is limited to eight hours. Automatic activities can continue
  across midnight within an overnight schedule; the displayed work totals reset
  at midnight in the Mac's timezone. Manually started activities end by midnight.
  Enable the daily schedule below to request a replacement when it expires.
  iOS may retain an ended activity on the Lock
  Screen for a while; active updates do not continue indefinitely. See Apple's
  [Live Activity constraints](https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities#Understand-constraints).
- The Mac checks for new phone connections and scheduled starts, renewals, and
  endings about once a minute. Changed totals are sent at that cadence; unchanged
  summaries and Live Activities refresh every three minutes. New activities and
  ending requests bypass duplicate suppression, and failed writes or pushes can
  retry on the next check. The phone also skips reapplying an identical snapshot.
  The break countdown ticks locally from its deadline without per-second
  pushes. Cloud-folder propagation and Apple's delivery policy can delay or
  combine break-state changes. A delayed update replaces the live countdown
  with the existing stale-data indication.

## Automatic daily starts and renewal

In Mac **Settings → iPhone Live Activity**, enable **Start and renew automatically
each day**. Choose **Every day** or **Weekdays (Mon–Fri)** under **Repeat**, select
the start time, and choose whether to stop renewing at the daily target, midnight,
or a fixed time. The schedule uses the Mac's local time. The target option skips
days with a zero target.

A fixed end time earlier than the start time means the following morning. The
repeat setting applies to the day the window starts. For example, **Weekdays**,
**7:00 AM** to **2:00 AM** runs from Monday morning through Tuesday at 2:00 AM,
and Friday's window continues until Saturday at 2:00 AM. It does not start on
Saturday or Sunday. Start and end times must differ.

At the daily target, automatic starts and renewals stop, but the current activity
continues updating until its original expiry so it can show overtime. A fixed
end time or midnight ends the current automatic activity at that cutoff.

Open the updated iPhone app once with the shared folder connected. On iOS 17.2
or later it shares a separate push-to-start token in `live-activity-devices`.
The Mac needs an imported APNs key, internet access, and Sundial running while
awake. After a late wake it starts during the remaining scheduled window; it
doesn't replay missed activities. iOS may delay or decline delivery. Renewal
starts a new activity with the current day's accumulated totals; it doesn't extend
Apple's eight-hour limit. An overnight schedule keeps the activity visible across
midnight while its displayed totals reset for the new Mac day. Each start requires
an Apple notification, without a requested sound, and a brief gap can occur during
renewal.

**Stop Live Activity** on iPhone pauses automatic starts through the current
scheduled window, including its following-morning end time. Outside an automatic
window, stopping pauses starts until the next Mac day. Starting manually resumes
them. Swipe dismissal is best effort because the app
may not run immediately; the explicit Stop control writes the pause immediately.
Folder delivery can still delay that pause reaching the Mac. Turning off the Mac
schedule prevents future automatic starts; an existing activity can finish normally.

The Mac saves each start attempt locally before contacting Apple. Accepted or
uncertain requests aren't retried until their intended expiry, avoiding duplicate
activities after delayed folder sync or a Mac restart. Explicit Apple rejections
back off for five minutes. If Apple accepted a start that never appears, reopen the
iPhone app and start manually. The iPhone also removes duplicate automatic
activities for the same device and day. Start registrations refresh while the
phone runs and expire from the Mac's perspective after 30 days without refresh.

The provider key stays in the Mac Keychain. The shared device registration contains
only its random device identifier, push token/environment, update timestamp, and
optional pause deadline. The local `live-activity-starts.json` file contains request
identifiers, dates, and retry deadlines, with no push tokens or provider key.

See Apple's [push-to-start documentation](https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications).

## Verify on a physical iPhone

1. Confirm a current summary appears in Today, start the activity, and compare
   its worked time and remainder with the Mac. A simulator preview does not
   establish APNs delivery to a real device.
2. Lock the phone. Accumulate enough classified work on the Mac to change a
   displayed minute, then confirm the locked activity changes without reopening
   Sundial. Check both the Mac's push status and the phone's displayed update.
3. Pause tracking or change the target on the Mac. Confirm the phone receives
   the changed state and remaining time.
4. Leave the Mac offline for over five minutes. Confirm the phone retains the
   last values and shows that the update is delayed. Reconnect and confirm that
   fresh data clears the stale state.

Until these steps pass with a provisioned device and APNs-capable key, locked
iPhone delivery remains unverified.
