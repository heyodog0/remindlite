import SwiftUI

/// One reminder row, flattened from EventKit so the UI never touches EKReminder.
struct TaskItem: Identifiable, Equatable {
    let id: String          // EKReminder.calendarItemIdentifier
    let title: String
    let due: Date?          // resolved start-of-day or date+time, nil if undated
    let hasTime: Bool       // due includes a clock time (vs. all-day)
    let priority: Int       // 0 none, 1 high … 9 low (EventKit convention)
    let notes: String?
    let completed: Bool
    let completionDate: Date?
    let listID: String      // EKCalendar.calendarIdentifier of the reminder's list
    let listName: String
    let listColor: Color

    // Equatable is synthesized over *all* fields so SwiftUI redraws a row when
    // any visible field changes (title, notes, due, priority, …). A hand-written
    // == that only compared id/completed silently dropped title/date/notes edits
    // — the change saved to Reminders but the row never refreshed.
}

/// One calendar event, flattened from EventKit so the UI never touches EKEvent.
/// (Includes any Google calendars synced into Apple Calendar via CalDAV.)
struct EventItem: Identifiable, Equatable {
    let id: String          // EKEvent.eventIdentifier (+ start, for recurring)
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarID: String
    let calendarName: String
    let calendarColor: Color
    let location: String?

    static func == (a: EventItem, b: EventItem) -> Bool { a.id == b.id }
}

/// One selectable event calendar, flattened from EKCalendar for the filter UI.
struct CalendarOption: Identifiable, Equatable {
    let id: String          // EKCalendar.calendarIdentifier
    let title: String
    let color: Color
    let account: String     // EKSource.title — iCloud, a Google account, Subscriptions…
}

/// An account (EKSource) a new reminder list can be created in.
struct SourceOption: Identifiable, Equatable {
    let id: String          // EKSource.sourceIdentifier
    let title: String       // iCloud, On My Mac, a Google account…
}

/// How a tab groups items: chronologically (date) or by their container
/// (`entity` = reminder list on the Reminders tab, calendar on the Calendar tab).
enum GroupMode: String { case date, entity }

/// A rendered group of reminders (a due-date bucket or a list), title + accent.
struct ReminderSection: Identifiable {
    let id: String
    let title: String
    let accent: Color
    let items: [TaskItem]
}

/// A rendered group of events (a day or a calendar), title + accent.
struct EventSection: Identifiable {
    let id: String
    let title: String
    let accent: Color
    let items: [EventItem]
}

/// Which list the panel is showing. (Named PanelTab to avoid SwiftUI's `Tab`.)
enum PanelTab: String, CaseIterable, Identifiable {
    case reminders, calendar
    var id: String { rawValue }
    var title: String { self == .reminders ? "Reminders" : "Calendar" }
    var icon: String { self == .reminders ? "checklist" : "calendar" }
}

/// Reminders-style priority marks: low `!`, medium `!!`, high `!!!` (nil = none).
/// EventKit priority is 1–4 high, 5 medium, 6–9 low, 0 none (the editor uses 1/5/9).
func priorityMarks(_ p: Int) -> (text: String, color: Color)? {
    switch p {
    case 1...4: return ("!!!", .red)
    case 5:     return ("!!", .orange)
    case 6...9: return ("!", .orange)
    default:    return nil
    }
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
