# QuickAdd

Floating quick-add box for Apple Reminders. Press **⌘⇧C** and a Spotlight-style
box opens next to your cursor and follows it.

## Download

https://github.com/Yangosss/Quickadd/releases/latest/download/QuickAdd.zip

Unzip, drag to Applications, right-click → Open the first time.

## Build from source

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
chmod +x build.sh && ./build.sh
cp -R build/QuickAdd.app /Applications/
open /Applications/QuickAdd.app
```

Click **Allow** when it asks for Reminders access.

## Usage

| Key        | Action                  |
|------------|-------------------------|
| `⌘⇧C`      | Open / close            |
| `↩`        | Add and close           |
| `⇧↩`       | Add and keep open       |
| `esc`      | Close                   |

## Syntax

Todoist-style. Shortcuts are lowercase only, so `call Tom` stays a name.

| Type | Examples |
|---|---|
| Day | `tod`, `tom`, `mon`…`sun`, `next fri`, `next week`, `next month`, `next year`, `this weekend`, `next weekend`, `eom`, `jan 27`, `27/1` |
| Time | `3pm`, `3:30pm`, `15:00`, `at 10`, `noon`, `tonight`, `tom morning`, `tod evening`, `in the afternoon` |
| Relative | `in 20 min`, `in 2 hours`, `in 5 days`, `+3 weeks`, `in 2 months` |
| Repeat | `daily`, `everyday`, `ev mon, fri`, `every workday`, `every weekend`, `every other week`, `every 3 months`, `quarterly`, `every 27th`, `ev 1, 15`, `every last day`, `every evening` |
| Repeat range | `until 31 dec`, `ending fri`, `for 3 weeks`, `for 10 times`, `starting jan 3` |
| List | `#Work`, `#Shopping_List` (`_` = space; prefix match works) |
| Priority | `p1` `p2` `p3` (`p4` = none) or `!!!` `!!` `!` |

Time words: morning 9am, afternoon 12pm, evening 7pm, night 10pm.

Examples:

- `email POSCO re offer fri 10am #Work p1`
- `gym ev mon, wed and fri 7am`
- `pay rent every 1st #Home`
- `stretch every evening for 30 days`

Rules:

- A time that has already passed today moves to tomorrow (`6pm` at 7pm → tomorrow).
- A weekday includes today (`fri` on a Friday = today); `next fri` is the one after.
- A date with no time → all-day reminder, alert at 09:00.
- A repeat with no date starts today, or on the next matching day.
- Unknown `#List` → saved to your default list (the preview warns you).
- Not supported (Reminders can't do them): `every!` (repeat from completion), hourly repeats.

## Menu bar

Follow Mouse (on/off), Launch at Login, Open Reminders, Quit.

## Customise

Edit `Config` at the top of `Sources/main.swift`, then rebuild:

- `hotKeyCode` / `hotKeyMods`: shortcut.
- `followSmoothing`: `1` snaps to the cursor, lower values glide.
- `allDayAlertHour`: alert time for date-only reminders.

## Notes

- ⌘⇧C is taken over system-wide while QuickAdd runs (e.g. Finder "Go to
  Computer", Chrome DevTools inspect).
- Builds are ad-hoc signed. After a rebuild macOS may ask for Reminders access
  again.
