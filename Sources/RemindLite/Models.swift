import SwiftUI

/// One reminder row, flattened from EventKit so the UI never touches EKReminder.
struct TaskItem: Identifiable, Equatable {
    let id: String          // EKReminder.calendarItemIdentifier
    let title: String
    let due: Date?          // resolved start-of-day or date+time, nil if undated
    let hasTime: Bool       // due includes a clock time (vs. all-day)
    let priority: Int       // 0 none, 1 high … 9 low (EventKit convention)
    let listID: String
    let listName: String
    let listColor: Color
    let notes: String?
    let completed: Bool
    let completionDate: Date?

    // Equatable is synthesized over *all* fields so SwiftUI redraws a row when
    // any visible field changes (title, notes, due, priority, …). A hand-written
    // == that only compared id/completed/color silently dropped title/date/notes
    // edits — the change saved to Reminders but the row never refreshed.

    /// Copy moved to a different list (for an optimistic "move to list").
    func withList(_ list: ReminderList) -> TaskItem {
        TaskItem(id: id, title: title, due: due, hasTime: hasTime, priority: priority,
                 listID: list.id, listName: list.name, listColor: list.color, notes: notes,
                 completed: completed, completionDate: completionDate)
    }
}

/// An Apple Reminders list (an EventKit reminder calendar).
struct ReminderList: Identifiable, Equatable {
    let id: String
    let name: String
    let color: Color
}

/// A preset list color, mirroring the Reminders app's palette.
struct ListColorOption: Identifiable, Equatable {
    let id: Int
    let name: String
    let color: Color
}

let reminderPalette: [ListColorOption] = [
    .init(id: 0, name: "Red",    color: Color(red: 1.00, green: 0.27, blue: 0.23)),
    .init(id: 1, name: "Orange", color: Color(red: 1.00, green: 0.58, blue: 0.00)),
    .init(id: 2, name: "Yellow", color: Color(red: 1.00, green: 0.80, blue: 0.00)),
    .init(id: 3, name: "Green",  color: Color(red: 0.30, green: 0.85, blue: 0.39)),
    .init(id: 4, name: "Blue",   color: Color(red: 0.00, green: 0.48, blue: 1.00)),
    .init(id: 5, name: "Purple", color: Color(red: 0.69, green: 0.32, blue: 0.87)),
    .init(id: 6, name: "Pink",   color: Color(red: 1.00, green: 0.18, blue: 0.57)),
    .init(id: 7, name: "Brown",  color: Color(red: 0.64, green: 0.52, blue: 0.37)),
]

/// One calendar event, flattened from EventKit so the UI never touches EKEvent.
/// (Includes any Google calendars synced into Apple Calendar via CalDAV.)
struct EventItem: Identifiable, Equatable {
    let id: String          // EKEvent.eventIdentifier (+ start, for recurring)
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarName: String
    let calendarColor: Color
    let location: String?

    static func == (a: EventItem, b: EventItem) -> Bool { a.id == b.id }
}

/// Which list the panel is showing. (Named PanelTab to avoid SwiftUI's `Tab`.)
enum PanelTab: String, CaseIterable, Identifiable {
    case reminders, calendar
    var id: String { rawValue }
    var title: String { self == .reminders ? "Reminders" : "Calendar" }
    var icon: String { self == .reminders ? "checklist" : "calendar" }
}

/// Compact time range for an event row, e.g. "All day", "3:00 – 4:00 PM".
func timeRange(_ e: EventItem) -> String {
    if e.isAllDay { return "All day" }
    let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
    return "\(f.string(from: e.start)) – \(f.string(from: e.end))"
}

/// Day header label for an event, e.g. "Today", "Tomorrow", "Friday", "Mar 12".
func dayHeader(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let days = calendar.dateComponents([.day],
        from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: day)).day ?? 0
    switch days {
    case 0:  return "Today"
    case 1:  return "Tomorrow"
    case 2...6:
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f.string(from: day)
    default:
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"; return f.string(from: day)
    }
}

/// Where a task sits relative to today — drives the panel's sections + badge.
enum Bucket: Int, CaseIterable, Identifiable {
    case overdue, today, upcoming, someday
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .overdue:  return "Overdue"
        case .today:    return "Today"
        case .upcoming: return "Upcoming"
        case .someday:  return "No Date"
        }
    }

    var accent: Color {
        switch self {
        case .overdue:  return .red
        case .today:    return .blue
        case .upcoming: return .secondary
        case .someday:  return .secondary
        }
    }

    /// Buckets that count toward the menu-bar badge (what's actionable now).
    static let badgeBuckets: [Bucket] = [.overdue, .today]
}

/// Classify a due date relative to the current day boundary.
func bucket(for due: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bucket {
    guard let due else { return .someday }
    let startToday = calendar.startOfDay(for: now)
    guard let startTomorrow = calendar.date(byAdding: .day, value: 1, to: startToday) else { return .someday }
    if due < startToday { return .overdue }
    if due < startTomorrow { return .today }
    return .upcoming
}

/// Compact relative-day label, e.g. "Today 3:00 PM", "Yesterday", "Fri", "Mar 12".
func dueLabel(_ due: Date?, hasTime: Bool, now: Date = Date(), calendar: Calendar = .current) -> String? {
    guard let due else { return nil }
    let startToday = calendar.startOfDay(for: now)
    let days = calendar.dateComponents([.day], from: startToday, to: calendar.startOfDay(for: due)).day ?? 0

    let dayPart: String
    switch days {
    case 0:   dayPart = "Today"
    case 1:   dayPart = "Tomorrow"
    case -1:  dayPart = "Yesterday"
    case 2...6:
        let f = DateFormatter(); f.dateFormat = "EEEE"; dayPart = f.string(from: due)
    default:
        let f = DateFormatter(); f.dateFormat = "MMM d"; dayPart = f.string(from: due)
    }
    if hasTime {
        let tf = DateFormatter(); tf.timeStyle = .short; tf.dateStyle = .none
        return "\(dayPart) \(tf.string(from: due))"
    }
    return dayPart
}
