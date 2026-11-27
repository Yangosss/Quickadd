// QuickAdd — floating, mouse-following quick-add box for Apple Reminders.
// Hotkey: ⌘⇧C  ·  Enter: add  ·  ⇧Enter: add & keep open  ·  Esc: close
//
// Syntax (Todoist-style):
//   tod / tom / mon / next fri / tom evening / 6pm / in 20 min / eom → due date (+ alert)
//   #Work  #Shopping_List                  → list (underscore = space, prefix match OK)
//   !!! / !! / !   or  p1 / p2 / p3 (p4 = none) → priority high / medium / low
//   daily / ev mon, wed / every 2 weeks / every workday / every 27th / every evening
//   … until 31 dec / for 10 times / starting jan 3                       → repeat

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
    var weekdays: [Int] = []   // Calendar weekday numbers: 1 = Sun … 7 = Sat
    var monthDays: [Int] = []  // 1…31, -1 = last day of month
    var endDate: Date?
    var count: Int?

    private static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    var label: String {
        var s: String
        if !weekdays.isEmpty {
            if weekdays == [2, 3, 4, 5, 6] { s = "Every weekday" }
            else if weekdays == [1, 7] { s = "Every weekend" }
            else { s = "Every " + weekdays.map { Repeat.dayNames[$0 - 1] }.joined(separator: ", ") }
        } else if !monthDays.isEmpty {
            s = "Monthly on " + monthDays.map { $0 == -1 ? "last day" : Repeat.ordinal($0) }.joined(separator: ", ")
        } else {
            let unit: String
            switch frequency {
            case .daily: unit = "day"
            case .weekly: unit = "week"
            case .monthly: unit = "month"
            default: unit = "year"
            }
            s = interval == 1
                ? ["day": "Daily", "week": "Weekly", "month": "Monthly", "year": "Yearly"][unit]!
                : "Every \(interval) \(unit)s"
        }
        if let endDate { s += " until \(Repeat.shortDate.string(from: endDate))" }
        if let count { s += " × \(count)" }
        return s
    }

    static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 100, n % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    var rule: EKRecurrenceRule {
        let days = weekdays.compactMap { EKWeekday(rawValue: $0) }.map { EKRecurrenceDayOfWeek($0) }
        let end: EKRecurrenceEnd? = endDate.map { EKRecurrenceEnd(end: $0) }
            ?? count.map { EKRecurrenceEnd(occurrenceCount: $0) }
        return EKRecurrenceRule(recurrenceWith: frequency, interval: interval,
                                daysOfTheWeek: days.isEmpty ? nil : days,
                                daysOfTheMonth: monthDays.isEmpty ? nil : monthDays.map { NSNumber(value: $0) },
                                monthsOfTheYear: nil, weeksOfTheYear: nil,
                                daysOfTheYear: nil, setPositions: nil, end: end)
    }
}

/// Date/time pieces found in the text. `exact` is used for "in 20 min" style times.
struct When {
    var day: Date?
    var time: (h: Int, m: Int)?
    var exact: Date?
    var rest: String
    var isEmpty: Bool { day == nil && time == nil && exact == nil }
}

enum Parser {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let timeHint = #"\d{1,2}(:\d{2})?\s*(am|pm)\b|\b\d{1,2}:\d{2}\b|\b(noon|midnight|morning|afternoon|evening|tonight|o'clock)\b"#
    private static var cal: Calendar { Calendar.current }

    // "tom"/"tod"/"ev" only match lowercase, so names like "call Tom" stay in the title.
    private static let todayWord = #"(?:today|(?-i:tod))"#
    private static let tomorrowWord = #"(?:tomorrow|tmrw?|(?-i:tom))"#
    private static let every = #"(?:every|(?-i:ev))"#
    private static let weekdayWord = #"(?:mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:r|rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?)s?"#
    private static let weekdayNumber = ["su": 1, "mo": 2, "tu": 3, "we": 4, "th": 5, "fr": 6, "sa": 7]
    private static let periodTime = ["morning": (9, 0), "afternoon": (12, 0), "evening": (19, 0), "night": (22, 0)]

    static func parse(_ raw: String) -> ParsedReminder {
        var p = ParsedReminder()
        var text = " \(raw) "

        // #List
        if let m = match(#"\s#([\p{L}\p{N}_\-]+)"#, in: text), let g = m.groups[0] {
            p.list = text[g].replacingOccurrences(of: "_", with: " ")
            text.replaceSubrange(m.whole, with: " ")
        }

        // Priority
        if let m = match(#"\s(!{1,3}|p[1-4])(?=\s)"#, in: text), let g = m.groups[0] {
            switch text[g].lowercased() {
            case "!!!", "p1": p.priority = 1
            case "!!", "p2": p.priority = 5
            case "!", "p3": p.priority = 9
            default: p.priority = 0  // p4 = no priority (Todoist default)
            }
            text.replaceSubrange(m.whole, with: " ")
        }

        // Repeat (before dates so "every mon" isn't read as a one-off date)
        var start: Date?
        if let r = parseRepeat(text) {
            p.repeatRule = r.rep
            text.replaceSubrange(r.range, with: r.replacement)

            // for 3 weeks / for 10 times
            if let m = match(#"\sfor\s+(\d+)\s+(days?|weeks?|months?|times)(?=\s)"#, in: text),
               let gn = m.groups[0], let gu = m.groups[1], let n = Int(text[gn]) {
                let unit = text[gu].lowercased()
                if unit.hasPrefix("time") {
                    p.repeatRule?.count = n
                } else {
                    let c: Calendar.Component = unit.hasPrefix("day") ? .day : unit.hasPrefix("week") ? .weekOfYear : .month
                    p.repeatRule?.endDate = cal.date(byAdding: c, value: n, to: Date()).map(endOfDay)
                }
                text.replaceSubrange(m.whole, with: " ")
            }
            // until 31 dec / ending fri
            if let (d, r) = dateAfter(#"until|ending(?:\s+on)?"#, in: text) {
                p.repeatRule?.endDate = endOfDay(d)
                text.replaceSubrange(r, with: " ")
            }
            // starting 3 jan / from mon
            if let (d, r) = dateAfter(#"starting(?:\s+on)?|from"#, in: text) {
                start = d
                text.replaceSubrange(r, with: " ")
            }
        }

        // Date / time
        var w = parseWhen(text)
        text = w.rest
        if let start { w.day = start }
        if let exact = w.exact {
            p.due = exact
            p.hasTime = true
        } else if w.day != nil || w.time != nil {
            var d = cal.startOfDay(for: w.day ?? Date())
            if let t = w.time {
                d = cal.date(bySettingHour: t.h, minute: t.m, second: 0, of: d) ?? d
                // "6pm" after 6pm → tomorrow (Todoist behaviour)
                if w.day == nil, d < Date() { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
                p.hasTime = true
            }
            p.due = d
        }

        // Repeats need a due date: default to today, snap to the next matching day.
        if let rep = p.repeatRule {
            var due = p.due ?? cal.startOfDay(for: Date())
            if !rep.weekdays.isEmpty || !rep.monthDays.isEmpty {
                due = nextMatching(due, rep)
                if p.hasTime, due < Date(), let next = cal.date(byAdding: .day, value: 1, to: due) {
                    due = nextMatching(next, rep)
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

    // MARK: Dates and times

    static func parseWhen(_ input: String, useDetector: Bool = true) -> When {
        var w = When(rest: input)
        var t = input
        let now = Date()
        let today = cal.startOfDay(for: now)

        func take(_ pattern: String) -> (whole: Range<String.Index>, groups: [String?])? {
            guard let m = match(pattern, in: t) else { return nil }
            let groups = m.groups.map { $0.map { String(t[$0]).lowercased() } }
            t.replaceSubrange(m.whole, with: " ")
            return (m.whole, groups)
        }
        func add(_ c: Calendar.Component, _ n: Int, to d: Date) -> Date? { cal.date(byAdding: c, value: n, to: d) }

        // in 20 min / in 2 hours / in 5 days / +3 weeks / in 2 months
        if let m = take(#"\s(?:in\s+|\+)(\d+)\s*(months?|mos?|minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|wks?|w)(?=\s)"#),
           let ns = m.groups[0], let n = Int(ns), let u = m.groups[1] {
            if u.hasPrefix("mo") { w.day = add(.month, n, to: today) }
            else if u.hasPrefix("m") { w.exact = now.addingTimeInterval(Double(n) * 60) }
            else if u.hasPrefix("h") { w.exact = now.addingTimeInterval(Double(n) * 3600) }
            else if u.hasPrefix("d") { w.day = add(.day, n, to: today) }
            else { w.day = add(.weekOfYear, n, to: today) }
        }

        // tom morning / tommorning / tod evening …
        if w.isEmpty, let m = take(#"\s("# + todayWord + "|" + tomorrowWord + #")\s*(morning|afternoon|evening|night)(?=\s)"#),
           let d = m.groups[0], let per = m.groups[1], let pt = periodTime[per] {
            w.day = d.hasPrefix("tod") ? today : add(.day, 1, to: today)
            w.time = (pt.0, pt.1)
        }

        // Day keywords
        if w.day == nil, w.exact == nil {
            if take(#"\s"# + todayWord + #"(?=\s)"#) != nil {
                w.day = today
            } else if take(#"\stonight(?=\s)"#) != nil {
                w.day = today
                w.time = (22, 0)
            } else if take(#"\s"# + tomorrowWord + #"(?=\s)"#) != nil {
                w.day = add(.day, 1, to: today)
            } else if take(#"\snext\s+week(?=\s)"#) != nil {
                w.day = nextWeekday(2, includeToday: false)
            } else if take(#"\snext\s+month(?=\s)"#) != nil {
                w.day = add(.month, 1, to: today)
            } else if take(#"\snext\s+year(?=\s)"#) != nil {
                let y = cal.component(.year, from: today) + 1
                w.day = cal.date(from: DateComponents(year: y, month: 1, day: 1))
            } else if let m = take(#"\s(this|next)\s+weekend(?=\s)"#) {
                let sat = nextWeekday(7, includeToday: true)
                w.day = m.groups[0] == "next" ? add(.day, 7, to: sat) : sat
            } else if take(#"\s(?:end\s+of\s+(?:the\s+)?month|eom)(?=\s)"#) != nil {
                if let first = cal.date(from: cal.dateComponents([.year, .month], from: today)),
                   let nextMonth = add(.month, 1, to: first) {
                    w.day = add(.day, -1, to: nextMonth)
                }
            } else if let m = take(#"\s(?:on\s+)?(next\s+|this\s+)?("# + weekdayWord + #")(?=\s)"#),
                      let tok = m.groups[1], let wd = weekdayNumber[String(tok.prefix(2))] {
                // "fri" = next Friday to occur (today counts); "next fri" = the one after
                let d = nextWeekday(wd, includeToday: true)
                w.day = (m.groups[0]?.hasPrefix("next") ?? false) ? add(.day, 7, to: d) : d
            }
        }

        // in the morning / this evening
        if w.time == nil, let m = take(#"\s(?:in\s+the|this)\s+(morning|afternoon|evening|night)(?=\s)"#),
           let per = m.groups[0], let pt = periodTime[per] {
            w.time = (pt.0, pt.1)
        }

        // Explicit times: 3pm, 3:30 pm, 15:00, at 10, noon
        if w.exact == nil {
            if let m = take(#"\s(?:at\s+|@)?(\d{1,2})(?::(\d{2}))?\s?(am|pm)(?=\s)"#),
               let hs = m.groups[0], var h = Int(hs), h >= 1, h <= 12 {
                let mins = m.groups[1].flatMap { Int($0) } ?? 0
                if m.groups[2] == "pm", h < 12 { h += 12 }
                if m.groups[2] == "am", h == 12 { h = 0 }
                w.time = (h, min(mins, 59))
            } else if let m = take(#"\s(?:at\s+|@)?([01]?\d|2[0-3]):([0-5]\d)(?=\s)"#),
                      let h = m.groups[0].flatMap({ Int($0) }), let mins = m.groups[1].flatMap({ Int($0) }) {
                w.time = (h, mins)
            } else if let m = take(#"\s(?:at\s+|@)(\d{1,2})(?=\s)"#),
                      let h = m.groups[0].flatMap({ Int($0) }), h <= 23 {
                w.time = (h >= 1 && h <= 6 ? h + 12 : h, 0)  // "at 3" → 3pm
            } else if let m = take(#"\s(?:at\s+)?(noon|midday|midnight)(?=\s)"#) {
                w.time = m.groups[0] == "midnight" ? (0, 0) : (12, 0)
            }
        }

        // Anything else (jan 27, 27/1, 3rd friday jan …) via Apple's date detector
        if useDetector, w.day == nil, w.exact == nil, let det = detector,
           let m = det.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
           let date = m.date, let r = Range(m.range, in: t) {
            let matched = String(t[r])
            let hasTime = matched.range(of: timeHint, options: [.regularExpression, .caseInsensitive]) != nil
            if hasTime, w.time == nil {
                let c = cal.dateComponents([.hour, .minute], from: date)
                w.time = (c.hour ?? 9, c.minute ?? 0)
                // time-only match: leave the day empty so "past time → tomorrow" applies
                if matched.range(of: #"[a-z]{3}|\d+[/.\-]\d+"#, options: [.regularExpression, .caseInsensitive]) != nil,
                   cal.startOfDay(for: date) != today {
                    w.day = cal.startOfDay(for: date)
                }
            } else {
                w.day = cal.startOfDay(for: date)
            }
            t.replaceSubrange(r, with: " ")
        }

        w.rest = t
        return w
    }

    /// Finds "<keyword> <date>" (date up to 3 words) and returns the date and the range to remove.
    private static func dateAfter(_ keywords: String, in text: String) -> (Date, Range<String.Index>)? {
        for n in stride(from: 3, through: 1, by: -1) {
            let words = #"(\S+"# + String(repeating: #"\s+\S+"#, count: n - 1) + ")"
            guard let m = match(#"\s(?:"# + keywords + #")\s+"# + words + #"(?=\s)"#, in: text),
                  let g = m.groups[0] else { continue }
            let w = parseWhen(" \(text[g]) ")
            if w.rest.trimmingCharacters(in: .whitespaces).isEmpty, let d = w.exact ?? w.day {
                return (d, m.whole)
            }
        }
        return nil
    }

    private static func nextWeekday(_ wd: Int, includeToday: Bool) -> Date {
        let today = cal.startOfDay(for: Date())
        for i in (includeToday ? 0 : 1)...7 {
            if let d = cal.date(byAdding: .day, value: i, to: today), cal.component(.weekday, from: d) == wd { return d }
        }
        return today
    }

    private static func endOfDay(_ d: Date) -> Date {
        cal.date(bySettingHour: 23, minute: 59, second: 0, of: d) ?? d
    }

    // MARK: Repeats

    private static func parseRepeat(_ text: String) -> (rep: Repeat, range: Range<String.Index>, replacement: String)? {
        // every morning / every evening → daily at that time
        if let m = match(#"\s"# + every + #"\s+(morning|afternoon|evening|night)(?=\s)"#, in: text), let g = m.groups[0] {
            return (Repeat(frequency: .daily), m.whole, " in the \(text[g]) ")
        }
        // daily / everyday / every day
        if let m = match(#"\s(?:daily|everyday|"# + every + #"\s+day)(?=\s)"#, in: text) {
            return (Repeat(frequency: .daily), m.whole, " ")
        }
        // every weekday / every workday / every weekend
        if let m = match(#"\s"# + every + #"\s+(?:weekdays?|workdays?)(?=\s)"#, in: text) {
            return (Repeat(frequency: .weekly, weekdays: [2, 3, 4, 5, 6]), m.whole, " ")
        }
        if let m = match(#"\s"# + every + #"\s+weekends?(?=\s)"#, in: text) {
            return (Repeat(frequency: .weekly, weekdays: [1, 7]), m.whole, " ")
        }
        // every 2 weeks / every other month / every 3 quarters
        if let m = match(#"\s"# + every + #"\s+(\d+|other)\s+(days?|weeks?|months?|quarters?|years?)(?=\s)"#, in: text),
           let gn = m.groups[0], let gu = m.groups[1] {
            var n = text[gn].lowercased() == "other" ? 2 : max(Int(text[gn]) ?? 1, 1)
            let unit = text[gu].lowercased()
            if unit.hasPrefix("quarter") { n *= 3 }
            return (Repeat(frequency: frequency(unit), interval: n), m.whole, " ")
        }
        // quarterly / every quarter
        if let m = match(#"\s(?:quarterly|"# + every + #"\s+quarter)(?=\s)"#, in: text) {
            return (Repeat(frequency: .monthly, interval: 3), m.whole, " ")
        }
        // weekly / monthly / yearly / every week / every month / every year
        if let m = match(#"\s(?:(weekly|monthly|yearly|annually)|"# + every + #"\s+(week|month|year))(?=\s)"#, in: text) {
            let word = (m.groups[0] ?? m.groups[1]).map { String(text[$0]) } ?? "week"
            return (Repeat(frequency: frequency(word)), m.whole, " ")
        }
        // every last day
        if let m = match(#"\s"# + every + #"\s+last\s+day(?=\s)"#, in: text) {
            return (Repeat(frequency: .monthly, monthDays: [-1]), m.whole, " ")
        }
        // every 27th / every 2, 15, 27
        let num = #"\d{1,2}(?:st|nd|rd|th)?"#
        if let m = match(#"\s"# + every + #"\s+("# + num + #"(?:\s*(?:,|and|&)\s*"# + num + #")*)(?=\s)"#, in: text),
           let g = m.groups[0] {
            let days = text[g].components(separatedBy: CharacterSet.decimalDigits.inverted)
                .compactMap { Int($0) }.filter { (1...31).contains($0) }
            if !days.isEmpty {
                return (Repeat(frequency: .monthly, monthDays: Array(Set(days)).sorted()), m.whole, " ")
            }
        }
        // every mon / every mon, wed and fri
        let list = #"\s"# + every + #"\s+("# + weekdayWord + #"(?:\s*(?:,|and|&)\s*"# + weekdayWord + #")*)(?=\s)"#
        if let m = match(list, in: text), let g = m.groups[0] {
            let days = text[g].lowercased()
                .components(separatedBy: CharacterSet.letters.inverted)
                .filter { $0.count >= 3 && $0 != "and" }
                .compactMap { weekdayNumber[String($0.prefix(2))] }
            if !days.isEmpty {
                return (Repeat(frequency: .weekly, weekdays: Array(Set(days)).sorted()), m.whole, " ")
            }
        }
        return nil
    }

    private static func frequency(_ word: String) -> EKRecurrenceFrequency {
        let w = word.lowercased()
        if w.hasPrefix("day") || w == "daily" { return .daily }
        if w.hasPrefix("month") || w.hasPrefix("quarter") { return .monthly }
        if w.hasPrefix("year") || w == "annually" { return .yearly }
        return .weekly
    }

    private static func nextMatching(_ date: Date, _ rep: Repeat) -> Date {
        for i in 0..<62 {
            guard let d = cal.date(byAdding: .day, value: i, to: date) else { continue }
            if !rep.weekdays.isEmpty {
                if rep.weekdays.contains(cal.component(.weekday, from: d)) { return d }
            } else {
                let day = cal.component(.day, from: d)
                let last = cal.range(of: .day, in: .month, for: d)?.count ?? 31
                if rep.monthDays.contains(day) || (rep.monthDays.contains(-1) && day == last) { return d }
            }
        }
        return date
    }

    private static var regexCache: [String: NSRegularExpression] = [:]

    /// Compiles each pattern once, then reuses it on every keystroke.
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        if let re = regexCache[pattern] { return re }
        let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        regexCache[pattern] = re
        return re
    }

    private static func match(_ pattern: String, in text: String)
        -> (whole: Range<String.Index>, groups: [Range<String.Index>?])? {
        guard let re = regex(pattern),
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
            preview.stringValue = "tom 3pm  ·  ev mon  ·  #List  ·  p1  —  ↩ add   ⇧↩ add another   esc close"
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
