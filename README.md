# RemindLite

A tiny native macOS menu-bar app that shows your **Apple Reminders** at a glance.
SwiftUI + AppKit + EventKit, real Liquid Glass, no dependencies.

## Features
- **Count badge** — the menu-bar icon carries a number: how many reminders are
  **overdue or due today**. It turns **red** when anything's overdue.
- **Two tabs** — a segmented **Reminders / Calendar** switch at the top of the
  glass panel.
- **Reminders** — grouped into **Overdue · Today · Upcoming · No Date**, sorted by
  due date then priority, with a **Completed** section for what you finished today.
  Tap a circle to check (or un-check) a task — it commits to Reminders instantly.
  Tap a task to edit its title, notes, due date, and priority. Quick-add a new one
  from the field at the bottom (it goes to your default Reminders list).
- **Calendar** — your next 7 days of events, grouped by day (**Today · Tomorrow ·
  …**) with times, locations, and per-calendar color bars. Reads Apple Calendar
  via EventKit, which **includes any Google calendars** you've synced into macOS
  (System Settings ▸ Internet Accounts) — no Google API needed.
- **Live** — refreshes automatically when Reminders or Calendar changes, and
  re-buckets across midnight on its own.

Right-click the menu-bar icon for **Refresh**, **Launch at Login**, and **Quit**.

## Build
```bash
./Scripts/build-app.sh && open dist/RemindLite.app
```
Requires **macOS 26 + Xcode 26** (uses the Liquid Glass `NSGlassEffectView` API).

## Permissions
On first click RemindLite asks for **Reminders** access; the first time you open
the **Calendar** tab it asks for **Calendar** access. These are separate EventKit
grants — approve them on demand, or later toggle them under *System Settings ▸
Privacy & Security ▸ Reminders / Calendars*. Everything is read locally through
EventKit; nothing leaves your machine.

### Persisting the grant across rebuilds (optional)
Ad-hoc signing means macOS re-asks for permission after each rebuild. To keep the
grant, create a stable self-signed identity once (Keychain Access ▸ Certificate
Assistant ▸ Create a Certificate, type *Code Signing*, named
`RemindLite Self-Signed`) and the build script picks it up automatically.

MIT © Ryan Truong. Clean-room — built against EventKit, no app decompiled.
