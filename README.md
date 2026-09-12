# Sundial

A Mac app that works out how much of your day was actually work.

A sundial reports the day it was actually given. Nothing to wind, no opinion of
its own, and nothing at all to say about the hours it could not see. That is the
whole design: the day is recorded as it happens, what any of it *meant* is
worked out afterwards from rules you can change, and time nobody observed is
left honestly blank.

Your activity record stays on your machine unless you enable backup to a folder
you choose. No account, no server, no screenshots.

**[Download Sundial for macOS](https://github.com/sanchitcop19/sundial/releases/latest)**
— requires macOS 14 or later. Open the DMG and drag Sundial into Applications.
Universal build for Apple silicon and Intel Macs. This first release is
**not notarized**; see [first-launch instructions](#install) below.

---

## The idea

Most automatic time trackers guess, and when they guess wrong you either accept
a bad number or spend your evening fixing entries by hand. Sundial is built
around the assumption that **it will get things wrong**, and that fixing it
should take one click and apply to everything.

Two design decisions follow from that.

**What you did is recorded; what it meant is worked out later.** The app stores
raw observations — the app in front, the tab, the browser profile, the project
folder, when you typed — and never stores a verdict. Verdicts are recomputed
from your rules every time. So changing a rule re-decides the whole history, not
just what happens next.

**Nothing is guessed.** If no rule matches, the time is *Unclassified* and shows
up in Review. An honest "I don't know" you can fix beats a confident wrong
answer you never notice.

## Fixing a wrong call

Click any block on the timeline and say what it should have been. The hard part
of writing a rule is choosing how broadly it applies, so that gets drafted for
you as a ladder of scopes:

```
You were on github.com/acme/api          currently: Work

This is  [ Work | Personal ]

Apply to
  ○ Only this page                 github.com/acme/api
  ● Everything under github.com/acme
  ○ Everything on github.com
  ○ All browsing in "Work"         the Work profile of Chrome
  ○ All of Google Chrome

  ⚠︎ 2h 14m would be reclassified, work −2h 14m.
     1h 40m of that already had a rule.
```

Every option is priced before you commit, and the warning appears when a rule
would take time away from a rule that already decided it — the usual sign that
it is too broad. New rules are inserted by how specific they are, so a broad
rule cannot silently swallow a precise one.

**Review** is the same thing in bulk: every unclassified context, biggest first,
with one-click Work / Personal.

## What the icon is telling you

The dot is what the time counts as. How it behaves is whether it is still being
earned.

| Icon | Meaning |
|---|---|
| ● pulsing | Work, and you are here. The number beside it is climbing |
| ● fading | Still counted as work, but quiet: it dims as the away cutoff approaches |
| ○ | Personal. Same fade, never a pulse — the work total is not moving |
| ◌ | Away. Nothing is being counted |
| ? | Nothing matched. Open the menu and give it a rule |
| ⏸ | Paused |
| ☕ after the total | A break is owed |

The pulse is the honest part. A stretch stays *work* for the whole two minutes
before the idle cutoff, so a dot that looked identical the moment you stopped
typing would be claiming you are at the keyboard when you are not. It stops
beating within seconds of you stopping and fades from there, and the menu says
how long is left: *Quiet for 45s — away in 1m 15s*.

A call keeps it beating. The microphone or camera being in use counts as
presence, so listening in a meeting stays alive; it dims across that much longer
window instead.

The dot fades down and back every second and a quarter, smoothly, at twenty-four
steps a second on a straight ramp. Settings has a slider for the rate, and since
the steps are timed rather than counted, a slower pulse is a smoother one at no
extra cost.

Getting there took four attempts, and the measurements are worth writing down.
The menu bar is composited over your wallpaper, so **setting the item's title
repaints a blurred strip and costs around eight milliseconds** - a twelve-frame
fade drawn that way measured a fifth of a core, all day. Handing the animation
to Core Animation made it worse, since it then ran at the display's full refresh
rate. Pinning the item's width changed nothing. Shrinking the item to just the
dot changed nothing either, so the price is neither layout nor area.

Two measurements pointed the way out. Ticking twelve times a second while
drawing nothing costs **0.3%** of a core, so polling is free and only visible
changes are billed. And a layer's opacity can be changed without rasterising
anything, which is roughly a tenth of the price of a redraw.

So the dot is not text. While it pulses it leaves the title, which holds its
place with a space kerned to the same width, and becomes a layer whose opacity
is stepped twenty-four times a second. The words are only redrawn when the words
change, which is about once a minute. A continuous fade now costs **~1% of a
core** against 6% for the four-step version it replaced, and nothing at all when
work is not being counted. If the layer cannot be placed the glyph stays as
text, so the worst case is a still icon rather than no icon. Reduce Motion drops
the fade entirely.

## Adding time by hand

For work the tracker could not see: a meeting away from the desk, a call taken
on a phone, a day spent on someone else's machine. **Today → Add time…**, or
from the command line:

Two commands answer "why was that counted as work?":

```bash
Sundial --why app=com.microsoft.VSCode project=~/repos/personal/thing
Sundial --breaks          # and why a break reminder did or did not appear
```

```bash
Sundial --add-time "yesterday 14:00" 90m work "offsite workshop"
Sundial --added 2026-09-02        # what has been added by hand that day
Sundial --remove-time a970f387    # by the id shown above
```

Entries are kept beside the observations, never mixed into them. The raw record
stays a record of what was actually on screen, an entry made by hand stays
visibly made by hand, and because nobody observed it, changing a rule later does
not re-decide it.

**Anything recorded underneath an entry is replaced, not added to.** Saying "I
was in a meeting from two until three" has to mean that hour counts once. On a
real day, adding 90 minutes over a window that already held 69 minutes of work
moved the day's work total by 21 minutes, not by 90, and the day's four totals
still summed to the same 23h 05m.

The awkward cases are handled rather than rejected out of hand: an entry
spanning midnight is split so each day's file still stands alone, and every
piece is checked before any of them is written. An entry cannot start in the
future, run backwards, last more than a day, or overlap another entry. A day
holding nothing but hand-entered time still appears in the day list, the
timeline and the CSV.

## Breaks

Optional, on by default, and it counts the thing a kitchen timer cannot: **work,
not wall clock**. Twenty-five minutes means twenty-five minutes of actual work.
Idle time, personal time and the stretch you spent making coffee do not add to
it, because the tracker already knows the difference.

- A break is time away from work at least as long as your break setting.
  Up to 15 seconds of work-app activity within the break is tolerated, so a
  quick glance does not erase your progress. Those work seconds pause the
  break timer; they do not help complete it. Longer work activity restarts it.
- Shorter interruptions are ignored: glancing at a message neither resets the
  count nor adds to it.
- Nothing is said while you are **already away** from the machine, or **in a
  call**. The break stays owed; the reminder waits for a moment when it is
  worth having.
- While a break remains owed, reminders appear at most once every 20 minutes,
  replacing the previous notification. Snooze postpones it for 20 minutes.
- **Skip break** clears the reminder and starts a fresh work interval before
  another break is due. It is available in the notification, fallback panel,
  and menu bar. Skipping does not change recorded work or daily statistics.
  Reminder timing and skips survive app restarts.
- The menu bar shows a small ☕ next to the total for as long as a break is
  owed, so the feature still works if you never grant notification access.
- Once a break is owed, taking a full break produces a single **Your break is
  over** notification with sound. It uses the configured break length and the
  same away, personal or unclassified time that resets the work count. If
  notifications are denied, it appears in Sundial's small reminder panel.
  Completion alerts are suppressed during calls and after a long sleep or
  tracking pause, so returning to the Mac does not announce an old break.

Notification permission is asked for the first time a break actually falls due,
never at launch.

## Accuracy

| Situation | What happens |
|---|---|
| You walk away, an agent keeps running | Away after 2 min of no input, counted from your **last keystroke**, not from when we noticed |
| You are in a call, not typing | Present. The microphone or camera being in use is the signal, so it works for Zoom, Meet, Teams, Slack huddles, anything |
| Lid closed, machine sleeps | The gap is Away, never credited to whatever was last on screen |
| Screen locked or asleep | Away |
| App crashes | The open stretch is committed on next launch; seconds lost, not hours |
| Two copies launched | The second exits. One writer only |
| Past midnight | Split, so each day's file stands alone |

Thresholds are settings, not decisions baked into the record — raising the idle
threshold re-decides history too.

## What it can tell apart

- **The same editor, used two ways.** A rule can key on the open folder, so
  `~/repos/work` counts as work while everything else under `~/repos` does not.
  The whole-app rung of the correction ladder is still offered for an editor,
  but it now says what it would swallow: one rule for all of VS Code quietly
  claims every personal repository too.
- **Browser tabs.** Chromium browsers and Safari over Apple Events. Firefox, Zen,
  LibreWolf and Waterfox read the address bar straight from the accessibility
  tree, which updates the instant you navigate — their session store is flushed
  only every ~15s, so trusting it would misfile a tab change for that whole
  window. The session store is still read, but only for what it alone knows:
  which container the tab is in.
- **Browser profiles and containers.** A Chrome "Work" profile or a Firefox/Zen
  work container is usually the cleanest work/personal split there is, and both
  are read. Chromium keeps its profile list in `Local State`, which macOS puts
  behind Full Disk Access — too large an ask — so the name is read off the
  toolbar profile chip instead, which needs nothing beyond Accessibility.
  Firefox containers come from the session store.

  Chromium URLs are read from the address bar for the same reason: Apple Events
  need a second permission that people often decline. Scripting is still used as
  a fallback where it is allowed.
- **Multi-account apps.** A Notion workspace is read from the window, so a work
  workspace and a personal one in the same app are told apart. Slack's workspace
  is matched as an exact title *segment*, so a channel named after your company
  in someone else's workspace does not count.
- **Editor and terminal projects.** The same editor is used for work and for
  side projects, so editors and terminals never get a blanket verdict — they are
  judged by the folder that is open. The folder in the title bar is resolved to
  a real path, so `~/work/api` and `~/side/api` are different things, and a
  project rule always outranks an app-wide one however they were added.

  A folder outside any known code root still keeps its name from the title, so
  the two projects stay distinguishable and each can be given its own rule
  (`Code whenever "scratchpad" is the open folder`).

## Install

1. [Download the latest DMG](https://github.com/sanchitcop19/sundial/releases/latest).
2. Open it and drag **Sundial** into **Applications**.
3. Open Sundial from Applications. Its icon appears in the menu bar.

Requires macOS 14 or later on Apple silicon or Intel.

**The first public release is ad-hoc signed and is not notarized.** macOS does
not verify its developer identity. After you first try to open Sundial, if
macOS blocks it, open **System Settings → Privacy & Security → Open Anyway**
for Sundial, then confirm **Open**. Only do this for a download you trust.
See [Apple's instructions](https://support.apple.com/en-us/102445).
You may need to grant Accessibility again after installing an update.

Grant **Accessibility** when asked — it reads the title of the active window.
Grant **Automation** for your browser the first time it asks, if you use Chrome,
Safari or another Chromium browser. Without them the app still tracks presence,
but cannot tell one tab or project from another.

Setup runs on first launch and asks about your company's domains, which browser
profiles are for work, which folders hold work code, and a handful of apps. All
of it is detected from your machine, and every answer becomes an ordinary rule
you can change later.

### Build from source

You need macOS 14 or later, the Swift 6 toolchain, and an Apple signing identity
in your keychain. `build-app.sh` uses a Developer ID Application certificate when
available, or an Apple Development certificate for local use. Set
`SUNDIAL_IDENTITY` to choose a specific identity.

```bash
git clone https://github.com/sanchitcop19/sundial.git
cd sundial
./build-app.sh          # builds and signs into ~/Applications
open ~/Applications/Sundial.app
```

### Publishing a build

The source repository and downloadable app are published separately. The
standard release workflow requires a **Developer ID Application** certificate
and notary credentials configured on the build machine:

```bash
./release.sh            # builds the DMG, signs, notarizes, and staples it
./publish.sh            # tags and uploads the DMG to a GitHub release
./downloads.sh          # shows download counts and repository traffic
```

To package an unnotarized universal build without Apple signing credentials:

```bash
SUNDIAL_VERSION=0.1.0 ./release.sh --preview
```

This writes `dist/Sundial-0.1.0.dmg` without updating an installed copy. Preview
releases must disclose their signing status and include the first-launch
instructions above. Use `SUNDIAL_VERSION` to set the version of a new release.

See [the distribution guide](docs/app-store.md) for credential setup and the
experimental Mac App Store packaging path. Signing keys, credentials, and
provisioning profiles should remain outside the public repository.

The icon is a placeholder. Redraw it in `Resources/make-icon.py` and re-run
`python3 Resources/make-icon.py` to regenerate the `.icns` and the 1024px
listing art.

## Statistics

The **Stats** tab opens with hours worked in the current calendar week
(Monday–Sunday), through today. Choose **This week**, **This month**,
**This quarter**, or **This year**; every total, chart, and other metric uses
the same selected calendar period, through the present. Statistics never use
rolling windows. Like everything else they are recomputed from the raw record
under the current rules, so fixing a rule corrects the history and the charts
with it.

Month, quarter, and year views lead with **average weekly hours worked**.
The average uses completed Monday–Sunday weeks wholly inside the selected
calendar period. The current week and weeks crossing the period boundary are
excluded. Weeks with no records are excluded; recorded weeks with no work count
as zero. With no completed recorded weeks, the average shows a dash. The period's
total work through today remains alongside it.

- **Work per day**, with weekends paler and the day in progress paler still.
- **When you work** — every hour of the day, summed across the period, with the
  core window worked out as the shortest run of hours holding 80% of the work.
  It also says how much falls outside that.
- **Hour by hour** — a heatmap, one row per day, one column per hour. This is
  where late nights, slow mornings and weekend creep show up.
- **Shape of the day** — typical start and finish (median, so one late night
  does not move it), what share of the working day was actually work, and how
  often the subject changed per hour.
- **Where the work went** — the biggest contexts across the period.

Daily averages describe a *finished* day, so the current one is excluded; with no
complete day in the period it says so rather than printing a small number. A span
crossing an hour boundary is divided between the hours it covers, using the
calendar rather than arithmetic so a daylight-saving change gives a 23- or
25-hour day.

**Longest focus** counts tracked work within a focus block, excluding pauses.
Time entered by hand still contributes to work totals and averages, but cannot
establish uninterrupted focus and is excluded from this metric.
Pauses longer than two minutes between work segments end the block, even when
a pause is split across several records. Gaps in recording follow the same
limit and never count as focus time.

The same thing on the command line, including an ASCII heatmap:

```bash
Sundial --stats            # Current calendar week, through today
Sundial --stats month      # Current calendar month, through today
Sundial --stats quarter    # Current calendar quarter, through today
Sundial --stats year       # Current calendar year, through today
```

`Sundial --stats week` is the explicit default. Numeric day counts are not
accepted.

## On your phone

`ios/` holds a companion app. It is a companion rather than a second tracker,
and the reason is a hard limit rather than a shortcut: **iOS gives no app any
way to see which other app you are using.** Screen Time's `DeviceActivity` data
is rendered inside its own extension and cannot be read even by the app that
hosts it. Anything claiming to track your phone automatically is either
guessing or is a VPN/MDM profile watching your traffic.

So the phone does the parts it is genuinely good at:

- **Review, anywhere.** The queue of unclassified time, with the same scope
  ladder the Mac offers. Deciding on the sofa teaches the Mac a rule for good.
- **Your day at a glance.** Today's totals, recent days, the stretch list.
- **Phone work you start yourself.** A labelled session with a stopwatch,
  recorded as your own entry and never presented as something measured.

Sync is over the same cloud folder the Mac backs up to — pick it once with the
file picker, no account and no server. The Mac owns the mirrored files, so the
phone never writes to them; it drops small files into an `inbox` folder that the
Mac drains on its backup cadence. One writer per file, nothing to conflict.

```bash
cd ios && xcodegen generate
open SundialMobile.xcodeproj
```

Turn on **Include the raw record** in the Mac app's backup settings, or the
phone can only show daily totals — it needs the observations to rebuild the
timeline and the review queue.

## Coming from another tracker

```bash
Sundial --import-workclock
```

Imports the earlier WorkClock tracker: its configuration is translated into
rules, and its recorded stretches become observations, so the history is
classified rather than dumped into Review. Stretches already covered by
Sundial are skipped, so the import is safe to re-run.

Two things are reconstructed rather than recovered, because the old data never
held them: the observation is rebuilt from the context key it recorded, and
presence comes from its own conclusions — time it called active becomes input,
time it called away becomes absence. That reproduces its numbers without
claiming a precision the old record never had.

## Command line

```bash
Sundial --report [YYYY-MM-DD]   # a day's totals, and what still needs a rule
Sundial --daily                 # every day, as a table
Sundial --rebuild               # recompute all history under the current rules
Sundial --login-item on|off     # launch at login
```

## Data

`~/Library/Application Support/Sundial/`

The app was called Escapement until it was renamed. An existing
`Application Support/Escapement` folder is moved here once, on first launch, so
the record carries over; if both exist the older one is left untouched rather
than merged.

| File | What it is |
|---|---|
| `days/observations-*.jsonl` | What was on screen, one line per stretch. The source of truth |
| `days/presence-*.json` | When you typed, when the screen was locked, when a call was on |
| `rules.json` | Your rules, in the order they apply |
| `daily.csv` | One row per day, with decimal hours for charting |

Because verdicts are derived, `daily.csv` and every total can be rebuilt from
the raw record at any time. Optional backup copies the CSV and your rules to
iCloud Drive, Dropbox, Google Drive or OneDrive — a copy rather than a symlink,
since the CSV is written with an atomic replace that would destroy one.

## Development

```bash
swift test
swift test --enable-code-coverage
```

`SundialCore` holds the model, rules, classifier, suggestions and storage. It
is pure — no AppKit, no clock, no globals — so classification, presence maths,
retroactive reclassification and the impact preview are all tested directly, and
it builds unchanged for iOS. `SundialApp` holds the macOS probes and UI;
`ios/` holds the companion.

## The first few minutes

Accessibility can only be asked for once the app is running, so the first
stretches are recorded before it is granted. During that window the process
name is visible — that needs no permission — but nothing inside the window is:
no tab, no workspace, no project.

Those stretches are marked at capture time and kept apart in Review under
**Cannot be classified**, with an explanation. They are not offered a rule,
because no rule could match something that was never recorded. Everything after
the grant is unaffected.

## Known limits

- Only the focused window is read, so a work window on a second monitor does not
  count while something else is in front.
- Reading without typing crosses the idle threshold. Raise it, or the call
  threshold covers you when a meeting is on.
- Chromium profile detection reads the window rather than the browser's API,
  because Chrome exposes no scripting hook for it. Firefox-family containers are
  exact.
- Arc and Dia are treated as ordinary Chromium browsers; their space concept is
  not read yet.
