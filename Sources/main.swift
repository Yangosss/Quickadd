// QuickAdd — floating, mouse-following quick-add box for Apple Reminders.
// Hotkey: ⌘⇧C  ·  Enter: add  ·  ⇧Enter: add & keep open  ·  Esc: close
//
// Syntax (Todoist-style):
//   tomorrow 3pm / next fri / in 20 min   → due date (+ alert)
//   #Work  #Shopping_List                  → list (underscore = space, prefix match OK)
//   !!! / !! / !   or  p1 / p2 / p3        → priority high / medium / low
//   daily / every mon, wed / every 2 weeks / every weekday / monthly → repeat

import AppKit
import Carbon.HIToolbox
import EventKit
import ServiceManagement

// MARK: - Config

enum Config {
    static let hotKeyCode = UInt32(kVK_ANSI_C)          // change key here
    static let hotKeyMods = UInt32(cmdKey | shiftKey)   // change modifiers here
    static let size = NSSize(width: 480, height: 78)
    static let mouseOffset: CGFloat = 18
    static let followSmoothing: CGFloat = 0.35          // 1 = snap, lower = smoother
    static let allDayAlertHour = 9
}

// MARK: - Parser

struct ParsedReminder {
    var title = ""
    var due: Date?
    var hasTime = false
    var list: String?
    var priority = 0  // EventKit: 0 none, 1 high, 5 medium, 9 low
    var repeatRule: Repeat?
}

struct Repeat {
    var frequency: EKRecurrenceFrequency
    var interval = 1
    var weekdays: [Int] = []  // Calendar weekday numbers: 1 = Sun … 7 = Sat

    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var label: String {
        if !weekdays.isEmpty {
            if weekdays == [2, 3, 4, 5, 6] { return "Every weekday" }
            if weekdays == [1, 7] { return "Every weekend" }
            return "Every " + weekdays.map { Repeat.dayNames[$0 - 1] }.joined(separator: ", ")
        }
        let unit: String
        switch frequency {
        case .daily: unit = "day"
        case .weekly: unit = "week"
        case .monthly: unit = "month"
        default: unit = "year"
        }
        if interval == 1 { return ["day": "Daily", "week": "Weekly", "month": "Monthly", "year": "Yearly"][unit]! }
        return "Every \(interval) \(unit)s"
    }

    var rule: EKRecurrenceRule {
        let days = weekdays.compactMap { EKWeekday(rawValue: $0) }.map { EKRecurrenceDayOfWeek($0) }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval,
                                daysOfTheWeek: days.isEmpty ? nil : days,
                                daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil,
                                daysOfTheYear: nil, setPositions: nil, end: nil)
    }
}

enum Parser {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let timeHint = #"\d{1,2}(:\d{2})?\s*(am|pm)\b|\b\d{1,2}:\d{2}\b|\b(noon|midnight|morning|afternoon|evening|tonight|o'clock)\b"#

    static func parse(_ raw: String) -> ParsedReminder {
        var p = ParsedReminder()
        var text = " \(raw) "

        // #List
        if let m = match(#"\s#([\p{L}\p{N}_\-]+)"#, in: text), let g = m.groups[0] {
            p.list = text[g].replacingOccurrences(of: "_", with: " ")
            text.replaceSubrange(m.whole, with: " ")
        }

        // Priority
        if let m = match(#"\s(!{1,3}|p[1-3])(?=\s)"#, in: text), let g = m.groups[0] {
            switch text[g].lowercased() {
            case "!!!", "p1": p.priority = 1
            case "!!", "p2": p.priority = 5
            default: p.priority = 9
            }
            text.replaceSubrange(m.whole, with: " ")
        }

        // Repeat (parsed before dates so "every mon" isn't read as a one-off date)
        if let (rep, range) = parseRepeat(text) {
            p.repeatRule = rep
            text.replaceSubrange(range, with: " ")
        }

        // "in 20 min" / "in 2 hours" / "in 3 days"
        if let m = match(#"\sin\s+(\d+)\s*(minutes?|mins?|m|hours?|hrs?|h|days?|d)(?=\s)"#, in: text),
           let gn = m.groups[0], let gu = m.groups[1], let n = Double(text[gn]) {
            let unit = text[gu].lowercased()
            let secs: Double = unit.hasPrefix("m") ? 60 : unit.hasPrefix("h") ? 3600 : 86400
            p.due = Date().addingTimeInterval(n * secs)
            p.hasTime = true
            text.replaceSubrange(m.whole, with: " ")
        }
        // Natural-language dates via NSDataDetector
        else if let det = detector,
                let m = det.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                let date = m.date, let r = Range(m.range, in: text) {
            let matched = String(text[r])
            p.due = date
            p.hasTime = matched.range(of: timeHint, options: [.regularExpression, .caseInsensitive]) != nil
            // "3pm" typed after 3pm → assume tomorrow (unless "today" was explicit)
            if p.hasTime, date < Date(), Date().timeIntervalSince(date) < 86400,
               matched.range(of: "today", options: .caseInsensitive) == nil {
                p.due = date.addingTimeInterval(86400)
            }
            text.replaceSubrange(r, with: " ")
        }

        // Repeats need a due date: default to today, and snap to the next matching weekday.
        if let rep = p.repeatRule {
            var due = p.due ?? Date()
            if !rep.weekdays.isEmpty {
                due = nextMatching(due, weekdays: rep.weekdays)
                if p.hasTime, due < Date() {
                    due = nextMatching(due.addingTimeInterval(86400), weekdays: rep.weekdays)
                }
            }
            p.due = due
        }

        p.title = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+(at|on|by|due)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return p
    }

    private static let weekdayWord = #"(?:mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:r|rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)s?"#

    private static func parseRepeat(_ text: String) -> (Repeat, Range<String.Index>)? {
        // daily / every day
        if let m = match(#"\s(?:daily|every\s+day)(?=\s)"#, in: text) {
            return (Repeat(frequency: .daily), m.whole)
        }
        // every weekday / every weekend
        if let m = match(#"\severy\s+weekdays?(?=\s)"#, in: text) {
            return (Repeat(frequency: .weekly, weekdays: [2, 3, 4, 5, 6]), m.whole)
        }
        if let m = match(#"\severy\s+weekends?(?=\s)"#, in: text) {
            return (Repeat(frequency: .weekly, weekdays: [1, 7]), m.whole)
        }
        // every 2 weeks / every other month
        if let m = match(#"\severy\s+(\d+|other)\s+(days?|weeks?|months?|years?)(?=\s)"#, in: text),
           let gn = m.groups[0], let gu = m.groups[1] {
            let n = text[gn].lowercased() == "other" ? 2 : max(Int(text[gn]) ?? 1, 1)
            return (Repeat(frequency: frequency(String(text[gu])), interval: n), m.whole)
        }
        // weekly / monthly / yearly / every week / every month / every year
        if let m = match(#"\s(?:(weekly|monthly|yearly|annually)|every\s+(week|month|year))(?=\s)"#, in: text) {
            let word = (m.groups[0] ?? m.groups[1]).map { String(text[$0]) } ?? "week"
            return (Repeat(frequency: frequency(word)), m.whole)
        }
        // every mon / every mon, wed and fri
        let list = #"\severy\s+("# + weekdayWord + #"(?:\s*(?:,|and|&)\s*"# + weekdayWord + #")*)(?=\s)"#
        if let m = match(list, in: text), let g = m.groups[0] {
            let order = ["su": 1, "mo": 2, "tu": 3, "we": 4, "th": 5, "fr": 6, "sa": 7]
            let days = text[g].lowercased()
                .components(separatedBy: CharacterSet.letters.inverted)
                .filter { $0.count >= 3 && $0 != "and" }
                .compactMap { order[String($0.prefix(2))] }
            if !days.isEmpty {
                return (Repeat(frequency: .weekly, weekdays: Array(Set(days)).sorted()), m.whole)
            }
        }
        return nil
    }

    private static func frequency(_ word: String) -> EKRecurrenceFrequency {
        let w = word.lowercased()
        if w.hasPrefix("day") || w == "daily" { return .daily }
        if w.hasPrefix("month") { return .monthly }
        if w.hasPrefix("year") || w == "annually" { return .yearly }
        return .weekly
    }

    private static func nextMatching(_ date: Date, weekdays: [Int]) -> Date {
        let cal = Calendar.current
        for i in 0..<7 {
            if let d = cal.date(byAdding: .day, value: i, to: date),
               weekdays.contains(cal.component(.weekday, from: d)) { return d }
        }
        return date
    }

    private static func match(_ pattern: String, in text: String)
        -> (whole: Range<String.Index>, groups: [Range<String.Index>?])? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let whole = Range(m.range, in: text) else { return nil }
        let groups = (1..<max(m.numberOfRanges, 1)).map { Range(m.range(at: $0), in: text) }
        return (whole, groups)
    }
}

// MARK: - Reminders store

struct QuickAddError: LocalizedError {
    let errorDescription: String?
    init(_ msg: String) { errorDescription = msg }
}

final class ReminderStore {
    private let store = EKEventStore()
    private(set) var granted = false
    private var cachedLists: [EKCalendar]?  // refreshed only when Reminders data changes

    init() {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            self?.cachedLists = nil
        }
    }

    private var lists: [EKCalendar] {
        if let c = cachedLists { return c }
        let c = store.calendars(for: .reminder)
        cachedLists = c
        return c
    }

    func requestAccess(_ done: @escaping (Bool) -> Void) {
        let handler: (Bool, Error?) -> Void = { ok, _ in
            DispatchQueue.main.async { self.granted = ok; self.cachedLists = nil; done(ok) }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToReminders(completion: handler)
        } else {
            store.requestAccess(to: .reminder, completion: handler)
        }
    }

    /// Exact (case-insensitive) match first, then prefix match.
    func list(named name: String?) -> EKCalendar? {
        guard let name, !name.isEmpty else { return nil }
        let n = name.lowercased()
        let cals = lists
        return cals.first { $0.title.lowercased() == n } ?? cals.first { $0.title.lowercased().hasPrefix(n) }
    }

    var defaultList: EKCalendar? { store.defaultCalendarForNewReminders() }

    /// Returns the name of the list it was saved to.
    func add(_ p: ParsedReminder) throws -> String {
        guard let cal = list(named: p.list) ?? defaultList else {
            throw QuickAddError("No Reminders list found")
        }
        let r = EKReminder(eventStore: store)
        r.title = p.title
        r.calendar = cal
        r.priority = p.priority
        if let due = p.due {
            var comps: Set<Calendar.Component> = [.year, .month, .day]
            if p.hasTime { comps.formUnion([.hour, .minute]) }
            r.dueDateComponents = Calendar.current.dateComponents(comps, from: due)
            let alertDate = p.hasTime ? due
                : Calendar.current.date(bySettingHour: Config.allDayAlertHour, minute: 0, second: 0, of: due) ?? due
            r.addAlarm(EKAlarm(absoluteDate: alertDate))
        }
        if let rep = p.repeatRule { r.addRecurrenceRule(rep.rule) }
        try store.save(r, commit: true)
        return cal.title
    }
}

// MARK: - Global hotkey (Carbon — no Accessibility permission needed)

final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    static var action: (() -> Void)?

    /// Returns nil if the shortcut is already taken by another app.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x5141_4444), id: 1) // 'QADD'
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { return nil }
    }
}

// MARK: - Panel

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let store = ReminderStore()
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private let field = NSTextField()
    private let preview = NSTextField(labelWithString: "")
    private var followTimer: Timer?
    private var followMouse = UserDefaults.standard.object(forKey: "followMouse") as? Bool ?? true

    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.doesRelativeDateFormatting = true
        return f
    }()

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMainMenu()
        buildStatusItem()
        buildPanel()
        store.requestAccess { _ in }
        hotKey = HotKey(keyCode: Config.hotKeyCode, modifiers: Config.hotKeyMods) { [weak self] in self?.toggle() }
        if hotKey == nil { alert("⌘⇧C is already used by another app. Change it in Config (main.swift).") }
    }

    // Hidden main menu so ⌘C/⌘V/⌘X/⌘A/⌘Z work inside the text field.
    private func buildMainMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let img = NSImage(systemSymbolName: "checklist", accessibilityDescription: "QuickAdd")
        img?.isTemplate = true
        statusItem.button?.image = img

        let menu = NSMenu()
        let newItem = NSMenuItem(title: "New Reminder", action: #selector(showFromMenu), keyEquivalent: "c")
        newItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(newItem)
        menu.addItem(.separator())

        let follow = NSMenuItem(title: "Follow Mouse", action: #selector(toggleFollow(_:)), keyEquivalent: "")
        follow.state = followMouse ? .on : .off
        menu.addItem(follow)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(NSMenuItem(title: "Open Reminders", action: #selector(openReminders), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit QuickAdd", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = menu
    }

    private func buildPanel() {
        let s = Config.size
        panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: s),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        // Spotlight-style frosted background
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: s))
        bg.material = .popover
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 14
        bg.layer?.masksToBounds = true
        panel.contentView = bg

        let icon = NSImageView(frame: NSRect(x: 16, y: 39, width: 22, height: 22))
        icon.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = .init(pointSize: 18, weight: .medium)
        bg.addSubview(icon)

        field.frame = NSRect(x: 46, y: 36, width: s.width - 60, height: 28)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20)
        field.placeholderString = "Remind me to…"
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingHead
        field.delegate = self
        bg.addSubview(field)

        preview.frame = NSRect(x: 47, y: 13, width: s.width - 61, height: 16)
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = .secondaryLabelColor
        preview.lineBreakMode = .byTruncatingTail
        bg.addSubview(preview)
    }

    // MARK: Show / hide

    private func toggle() { panel.isVisible ? hide() : show() }
    @objc private func showFromMenu() { show() }

    private func show() {
        field.stringValue = ""
        updatePreview()
        panel.setFrameOrigin(targetOrigin())
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        panel.invalidateShadow()
        startFollowing()
    }

    private func hide() {
        guard panel.isVisible else { return }
        stopFollowing()
        panel.orderOut(nil)
        NSApp.hide(nil) // hand focus back to the previous app
    }

    func windowDidResignKey(_ note: Notification) { hide() }

    // MARK: Follow mouse

    private func startFollowing() {
        stopFollowing()
        let t = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        followTimer = t
    }

    private func stopFollowing() { followTimer?.invalidate(); followTimer = nil }

    @objc private func tick() {
        guard followMouse, panel.isVisible else { return }
        let target = targetOrigin()
        var o = panel.frame.origin
        let dx = target.x - o.x, dy = target.y - o.y
        guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }
        o.x += dx * Config.followSmoothing
        o.y += dy * Config.followSmoothing
        panel.setFrameOrigin(o)
    }

    /// Bottom-right of the cursor; flips left/up near screen edges.
    private func targetOrigin() -> NSPoint {
        let m = NSEvent.mouseLocation
        let size = panel.frame.size
        let off = Config.mouseOffset
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main
        else { return m }
        let vf = screen.visibleFrame
        var x = m.x + off
        var y = m.y - off - size.height
        if x + size.width > vf.maxX { x = m.x - off - size.width }
        if y < vf.minY { y = m.y + off }
        x = min(max(x, vf.minX), vf.maxX - size.width)
        y = min(max(y, vf.minY), vf.maxY - size.height)
        return NSPoint(x: x, y: y)
    }

    // MARK: Text field

    func controlTextDidChange(_ note: Notification) { updatePreview() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            submit(keepOpen: NSEvent.modifierFlags.contains(.shift)); return true
        case #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            submit(keepOpen: true); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        default:
            return false
        }
    }

    private func updatePreview() {
        preview.textColor = .secondaryLabelColor
        let p = Parser.parse(field.stringValue)
        guard store.granted else {
            preview.stringValue = "⚠︎ Allow Reminders: System Settings › Privacy & Security › Reminders"
            return
        }
        guard !p.title.isEmpty || p.due != nil else {
            preview.stringValue = "tomorrow 3pm  ·  every mon  ·  #List  ·  !!!  —  ↩ add   ⇧↩ add another   esc close"
            return
        }
        var parts: [String] = []
        if let due = p.due {
            dateFmt.timeStyle = p.hasTime ? .short : .none
            parts.append("📅 \(dateFmt.string(from: due))")
        }
        if let name = p.list {
            parts.append(store.list(named: name).map { "📋 \($0.title)" }
                         ?? "📋 \(store.defaultList?.title ?? "Default") (no list “\(name)”)")
        } else {
            parts.append("📋 \(store.defaultList?.title ?? "Default")")
        }
        switch p.priority {
        case 1: parts.append("⚑ High")
        case 5: parts.append("⚑ Medium")
        case 9: parts.append("⚑ Low")
        default: break
        }
        if let rep = p.repeatRule { parts.append("🔁 \(rep.label)") }
        preview.stringValue = parts.joined(separator: "   ")
    }

    private func submit(keepOpen: Bool) {
        let p = Parser.parse(field.stringValue)
        guard !p.title.isEmpty else { NSSound.beep(); return }
        guard store.granted else { store.requestAccess { [weak self] _ in self?.updatePreview() }; return }
        do {
            let listName = try store.add(p)
            preview.textColor = .systemGreen
            preview.stringValue = "✓ Added to \(listName)"
            field.stringValue = ""
            if !keepOpen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.hide() }
            }
        } catch {
            preview.textColor = .systemRed
            preview.stringValue = "⚠︎ \(error.localizedDescription)"
        }
    }

    // MARK: Menu actions

    @objc private func toggleFollow(_ item: NSMenuItem) {
        followMouse.toggle()
        UserDefaults.standard.set(followMouse, forKey: "followMouse")
        item.state = followMouse ? .on : .off
    }

    @objc private func toggleLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { alert("Launch at Login failed: \(error.localizedDescription)\nMove QuickAdd.app to /Applications first.") }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openReminders() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app"))
    }

    private func alert(_ msg: String) {
        let a = NSAlert()
        a.messageText = "QuickAdd"
        a.informativeText = msg
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
app.run()
