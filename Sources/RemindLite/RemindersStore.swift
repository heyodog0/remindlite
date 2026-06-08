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

    /// All calendars that can hold events, for the per-calendar filter UI.
    func eventCalendars() -> [EKCalendar] { store.calendars(for: .event) }

    /// All reminder lists, for the list picker + filter UI.
    func reminderLists() -> [EKCalendar] { store.calendars(for: .reminder) }

    /// Identifier of the list new reminders go to by default.
    func defaultReminderListID() -> String? {
        store.defaultCalendarForNewReminders()?.calendarIdentifier
    }

    /// Accounts a new reminder list can be created in: those that already hold
    /// reminder lists (e.g. iCloud), plus the on-device Local source. (Google
    /// CalDAV generally can't create reminder lists, so it's excluded.)
    func reminderSources() -> [EKSource] {
        store.sources.filter {
            !$0.calendars(for: .reminder).isEmpty || $0.sourceType == .local
        }
    }

    /// Source new reminders' default list lives in — the safest default target.
    func defaultReminderSourceID() -> String? {
        store.defaultCalendarForNewReminders()?.source.sourceIdentifier
    }

    /// Create a new reminder list in `sourceID` (or the default account). Returns
    /// the new list's identifier on success, nil on failure, on main.
    func createReminderList(title: String, sourceID: String?,
                            _ done: @escaping (String?) -> Void) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { done(nil); return }
        let source = sourceID.flatMap { id in store.sources.first { $0.sourceIdentifier == id } }
            ?? store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first { $0.sourceType == .local }
        guard let source else { done(nil); return }
        let cal = EKCalendar(for: .reminder, eventStore: store)
        cal.title = t
        cal.source = source
        do {
            try store.saveCalendar(cal, commit: true)
            let id = cal.calendarIdentifier
            DispatchQueue.main.async { done(id) }
        } catch {
            DispatchQueue.main.async { done(nil) }
        }
    }

    /// Look up calendars of `entity` by identifier (the enabled set from AppState).
    func calendars(withIDs ids: [String], entity: EKEntityType) -> [EKCalendar] {
        let wanted = Set(ids)
        return store.calendars(for: entity).filter { wanted.contains($0.calendarIdentifier) }
    }

    /// Fetch events from now through `days` ahead, flattened + sorted. Main thread.
    /// `calendars: nil` means every calendar; an explicit list restricts to those.
    func fetchEvents(days: Int, calendars: [EKCalendar]?,
                     _ done: @escaping ([EventItem]) -> Void) {
        let cal = Calendar.current
        let start = Date()
        let end = cal.date(byAdding: .day, value: days, to: cal.startOfDay(for: start)) ?? start
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
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
    func fetchAll(calendars: [EKCalendar]?, _ done: @escaping ([TaskItem]) -> Void) {
        let incompletePred = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: calendars)
        let startToday = Calendar.current.startOfDay(for: Date())
        let completedPred = store.predicateForCompletedReminders(
            withCompletionDateStarting: startToday, ending: nil, calendars: calendars)

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

    /// Update a reminder's editable fields and commit. `done` runs on main.
    func update(id: String, title: String, notes: String, due: Date?, hasTime: Bool,
                priority: Int, listID: String?, _ done: @escaping () -> Void) {
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { done(); return }
        r.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        r.notes = notes.isEmpty ? nil : notes
        r.priority = priority
        // Move to a different list if asked (and the target exists). Cross-source
        // moves can fail in EventKit; try? swallows that and keeps the other edits.
        if let listID, r.calendar?.calendarIdentifier != listID,
           let newCal = store.calendars(for: .reminder)
               .first(where: { $0.calendarIdentifier == listID }) {
            r.calendar = newCal
        }
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

    /// Create a new reminder in `listID` (or the default list if nil/missing),
    /// optionally with notes.
    func add(title: String, listID: String?, notes: String, _ done: @escaping () -> Void) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cal = listID.flatMap { id in
            store.calendars(for: .reminder).first { $0.calendarIdentifier == id }
        } ?? store.defaultCalendarForNewReminders()
        guard !t.isEmpty, let cal else { done(); return }
        let r = EKReminder(eventStore: store)
        r.title = t
        let n = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { r.notes = n }
        r.calendar = cal
        try? store.save(r, commit: true)
        DispatchQueue.main.async { done() }
    }

    /// Recolor a calendar / reminder list and commit. `done` runs on main.
    func setCalendarColor(_ id: String, cgColor: CGColor, _ done: @escaping () -> Void) {
        guard let cal = store.calendar(withIdentifier: id) else { done(); return }
        cal.cgColor = cgColor
        try? store.saveCalendar(cal, commit: true)
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
        let listColor = cg.map { Color(cgColor: $0) } ?? .secondary
        return TaskItem(
            id: r.calendarItemIdentifier,
            title: r.title ?? "Untitled",
            due: due,
            hasTime: hasTime,
            priority: r.priority,
            notes: r.notes,
            completed: r.isCompleted,
            completionDate: r.completionDate,
            listID: r.calendar?.calendarIdentifier ?? "",
            listName: r.calendar?.title ?? "",
            listColor: listColor)
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
            calendarID: e.calendar?.calendarIdentifier ?? "",
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
