import EventKit
import AppKit
import SwiftUI

/// Thin EventKit wrapper. Owns the single EKEventStore, handles the macOS 14+
/// full-access grant, and translates EKReminder ⇄ TaskItem. All completion
/// handlers fire on arbitrary queues, so callers are invoked back on `.main`.
final class RemindersStore {
    let store = EKEventStore()

    enum Access { case unknown, granted, denied }

    /// Current authorization mapped to our three-state view of the world.
    var access: Access {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:           return .granted
        case .denied, .restricted:  return .denied
        case .notDetermined:        return .unknown
        case .writeOnly:            return .denied   // can't read the list
        @unknown default:           return .unknown
        }
    }

    /// Calendar (events) authorization — a separate grant from reminders.
    var calendarAccess: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:           return .granted
        case .denied, .restricted:  return .denied
        case .notDetermined:        return .unknown
        case .writeOnly:            return .denied
        @unknown default:           return .unknown
        }
    }

    /// Prompt for (or silently confirm) full reminder access. `done` runs on main.
    func requestAccess(_ done: @escaping (Bool) -> Void) {
        store.requestFullAccessToReminders { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
    }

    /// Prompt for (or silently confirm) full calendar access. `done` runs on main.
    func requestCalendarAccess(_ done: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
    }

    /// Fetch events from now through `days` ahead, flattened + sorted. Main thread.
    func fetchEvents(days: Int, _ done: @escaping ([EventItem]) -> Void) {
        let cal = Calendar.current
        let start = Date()
        let end = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: start)) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        // fetchEvents is synchronous; hop off the main thread to stay responsive.
        DispatchQueue.global(qos: .userInitiated).async { [store] in
            let items = store.events(matching: predicate)
                .map(Self.item(from:))
                .sorted(by: Self.before)
            DispatchQueue.main.async { done(items) }
        }
    }

    /// Fetch all incomplete reminders plus the ones completed *today*, flattened
    /// and sorted. `done` runs on main. The completed set is bounded to today so
    /// the "Completed" section stays short and resets each morning.
    func fetchAll(_ done: @escaping ([TaskItem]) -> Void) {
        let incompletePred = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil)
        let startToday = Calendar.current.startOfDay(for: Date())
        let completedPred = store.predicateForCompletedReminders(
            withCompletionDateStarting: startToday, ending: nil, calendars: nil)

        store.fetchReminders(matching: incompletePred) { [store] inc in
            store.fetchReminders(matching: completedPred) { comp in
                let open = (inc ?? []).map(Self.item(from:)).sorted(by: Self.before)
                let done0 = (comp ?? []).map(Self.item(from:)).sorted {
                    ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast)
                }
                DispatchQueue.main.async { done(open + done0) }
            }
        }
    }

    /// Mark a reminder complete (or not) by identifier and commit. Returns on main.
    func setCompleted(_ id: String, _ completed: Bool, _ done: @escaping () -> Void) {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { done(); return }
        r.isCompleted = completed
        try? store.save(r, commit: true)
        DispatchQueue.main.async { done() }
    }

    /// All reminder lists, sorted by name. (EventKit reminder calendars.)
    func lists() -> [ReminderList] {
        store.calendars(for: .reminder).map { cal in
            ReminderList(id: cal.calendarIdentifier,
                         name: cal.title,
                         color: Color(cgColor: cal.cgColor))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Identifier of the list new reminders default to.
    func defaultListID() -> String? {
        store.defaultCalendarForNewReminders()?.calendarIdentifier
    }

    /// Create a new reminder list with a color. Returns the id (or nil) on main.
    func createList(name: String, color: Color, _ done: @escaping (String?) -> Void) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { done(nil); return }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = n
        cal.cgColor = NSColor(color).cgColor
        // Put it in the same source as the default list (e.g. iCloud), falling
        // back to a local/CalDAV source.
        cal.source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first { $0.sourceType == .local }
            ?? store.sources.first { $0.sourceType == .calDAV }
            ?? store.sources.first
        do {
            try store.saveCalendar(cal, commit: true)
            DispatchQueue.main.async { done(cal.calendarIdentifier) }
        } catch {
            NSLog("RemindLite: create list failed: \(error.localizedDescription)")
            DispatchQueue.main.async { done(nil) }
        }
    }

    /// Move a reminder to another list (calendar) by identifier. Main thread.
    func move(_ id: String, toListID listID: String, _ done: @escaping () -> Void) {
        if let r = store.calendarItem(withIdentifier: id) as? EKReminder,
           let cal = store.calendar(withIdentifier: listID) {
            r.calendar = cal
            try? store.save(r, commit: true)
        }
        DispatchQueue.main.async { done() }
    }

    /// Update a reminder's editable fields and commit. `done` runs on main.
    func update(id: String, title: String, notes: String, due: Date?, hasTime: Bool,
                priority: Int, listID: String, _ done: @escaping () -> Void) {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { done(); return }
        r.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        r.notes = notes.isEmpty ? nil : notes
        r.priority = priority
        if let due {
            var comps = Calendar.current.dateComponents([.year, .month, .day], from: due)
            if hasTime {
                let t = Calendar.current.dateComponents([.hour, .minute], from: due)
                comps.hour = t.hour; comps.minute = t.minute
            }
            r.dueDateComponents = comps
        } else {
            r.dueDateComponents = nil
        }
        if let cal = store.calendar(withIdentifier: listID) { r.calendar = cal }
        try? store.save(r, commit: true)
        DispatchQueue.main.async { done() }
    }

    /// Permanently delete a reminder by identifier. `done` runs on main.
    func delete(_ id: String, _ done: @escaping () -> Void) {
        if let r = store.calendarItem(withIdentifier: id) as? EKReminder {
            try? store.remove(r, commit: true)
        }
        DispatchQueue.main.async { done() }
    }

    /// Create a new reminder in the given list (or the default). `done` on main.
    func add(title: String, listID: String?, _ done: @escaping () -> Void) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cal = listID.flatMap { store.calendar(withIdentifier: $0) }
            ?? store.defaultCalendarForNewReminders()
        guard !t.isEmpty, let cal else { done(); return }
        let r = EKReminder(eventStore: store)
        r.title = t
        r.calendar = cal
        try? store.save(r, commit: true)
        DispatchQueue.main.async { done() }
    }

    // MARK: - translation

    private static func item(from r: EKReminder) -> TaskItem {
        var due: Date?
        var hasTime = false
        if let comps = r.dueDateComponents {
            hasTime = comps.hour != nil
            due = Calendar.current.date(from: comps)
        }
        let cg = r.calendar?.cgColor
        let color = cg.map { Color(cgColor: $0) } ?? .secondary
        return TaskItem(
            id: r.calendarItemIdentifier,
            title: r.title ?? "Untitled",
            due: due,
            hasTime: hasTime,
            priority: r.priority,
            listID: r.calendar?.calendarIdentifier ?? "",
            listName: r.calendar?.title ?? "",
            listColor: color,
            notes: r.notes,
            completed: r.isCompleted,
            completionDate: r.completionDate)
    }

    private static func item(from e: EKEvent) -> EventItem {
        let cg = e.calendar?.cgColor
        let color = cg.map { Color(cgColor: $0) } ?? .secondary
        // eventIdentifier is shared across a recurring series, so disambiguate
        // each occurrence by its start time.
        let base = e.eventIdentifier ?? e.title ?? "event"
        return EventItem(
            id: "\(base)@\(e.startDate.timeIntervalSinceReferenceDate)",
            title: e.title ?? "Untitled",
            start: e.startDate,
            end: e.endDate,
            isAllDay: e.isAllDay,
            calendarName: e.calendar?.title ?? "",
            calendarColor: color,
            location: e.location)
    }

    /// Sort events chronologically; all-day events lead their day.
    private static func before(_ a: EventItem, _ b: EventItem) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }

    /// Sort: earlier due first, undated last; within a day high priority first.
    private static func before(_ a: TaskItem, _ b: TaskItem) -> Bool {
        switch (a.due, b.due) {
        case let (x?, y?) where x != y: return x < y
        case (nil, .some):  return false
        case (.some, nil):  return true
        default: break
        }
        // EventKit priority: 1 (high) … 9 (low), 0 = none → treat as 10.
        let pa = a.priority == 0 ? 10 : a.priority
        let pb = b.priority == 0 ? 10 : b.priority
        if pa != pb { return pa < pb }
        return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }
}
