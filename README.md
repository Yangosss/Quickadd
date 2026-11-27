# QuickAdd

Floating quick-add box for Apple Reminders. Press **⌘⇧C** and a Spotlight-style
box opens next to your cursor and follows it.

## Build and install

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

| Type               | Example                           |
|--------------------|-----------------------------------|
| Date / time        | `tomorrow 3pm`, `next fri`, `in 20 min` |
| List               | `#Work`, `#Shopping_List` (`_` = space; prefix match works) |
| Priority           | `!!!` / `!!` / `!` or `p1` / `p2` / `p3` |
| Repeat             | `daily`, `weekly`, `monthly`, `yearly`, `every mon, wed and fri`, `every weekday`, `every 2 weeks`, `every other month` |

Examples:

- `email POSCO re offer fri 10am #Work !!!`
- `gym every mon, wed and fri 7am`
- `pay rent monthly #Home`

- Date with no time → all-day reminder, alert at 09:00.
- A repeat with no date starts today (or the next matching weekday).
- Unknown `#List` → saved to your default list (the preview warns you).

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
