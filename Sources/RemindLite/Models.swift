// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import SwiftUI

/// One reminder row, flattened from EventKit so the UI never touches EKReminder.
struct TaskItem: Identifiable, Equatable {
    let id: String          // EKReminder.calendarItemIdentifier — local to this Mac
    /// calendarItemExternalIdentifier: the server's id, the same on every device
    /// (what the shared Now list pins by).
    let externalID: String
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
    /// iCalendar UID (EKEvent.calendarItemExternalIdentifier) — what Google's
    /// API calls iCalUID; matches the event to its Google color.
    let externalID: String?
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarID: String
    let calendarName: String
    let calendarColor: Color
    let location: String?
    // Details for the event screen (all from EventKit — what Calendar.app
    // syncs from Google over CalDAV).
    let notes: String?
    let url: URL?
    /// Video-call link found in the event (Meet, Zoom, Teams, Webex), if any.
    let meeting: MeetingLink?
    let organizer: String?
    let attendees: [Attendee]
    let isCanceled: Bool

    // Equatable is synthesized over all fields (see TaskItem): comparing only
    // `id` meant a renamed or rescheduled event never redrew its row.
}

extension EventItem {
    /// A copy at Google's newer time and title, before EventKit has them.
    func updated(title: String, start: Date, end: Date, allDay: Bool, location: String?) -> EventItem {
        EventItem(id: id, externalID: externalID, title: title, start: start, end: end, isAllDay: allDay,
                  calendarID: calendarID, calendarName: calendarName, calendarColor: calendarColor,
                  location: location, notes: notes, url: url, meeting: meeting, organizer: organizer,
                  attendees: attendees, isCanceled: isCanceled)
    }
}

/// One invitee and their RSVP, flattened from EKParticipant.
struct Attendee: Identifiable, Equatable {
    enum RSVP { case accepted, declined, tentative, pending }
    let id: String          // email when known, else the display name
    let name: String
    let rsvp: RSVP
    let isOrganizer: Bool
    let isMe: Bool
}

/// A joinable video call, with the service named for the button label.
struct MeetingLink: Equatable {
    let url: URL
    let service: String     // "Google Meet", "Zoom", …

    private static let services: [(host: String, name: String)] = [
        ("meet.google.com", "Google Meet"), ("zoom.us", "Zoom"),
        ("teams.microsoft.com", "Teams"), ("teams.live.com", "Teams"),
        ("webex.com", "Webex"), ("facetime.apple.com", "FaceTime"),
    ]

    /// The first known video-call link in any of `texts` (URL field, location,
    /// notes — Google puts the Meet link in the description).
    static func find(in texts: [String?]) -> MeetingLink? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        for case let text? in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                guard let url = match.url, let host = url.host?.lowercased() else { continue }
                if let svc = services.first(where: { host == $0.host || host.hasSuffix("." + $0.host) }) {
                    return MeetingLink(url: url, service: svc.name)
                }
            }
        }
        return nil
    }
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

/// Formatters are costly to create and these run per row on every redraw, so
/// build each once.
enum Formatters {
    static let time: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; return f
    }()
    static let weekday = fixed("EEEE")
    static let shortDate = fixed("MMM d")
    static let weekdayDate = fixed("EEE, MMM d")
    private static func fixed(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.dateFormat = format; return f
    }
}

/// Compact time range for an event row, e.g. "All day", "3:00 – 4:00 PM".
func timeRange(_ e: EventItem) -> String {
    if e.isAllDay { return "All day" }
    return "\(Formatters.time.string(from: e.start)) – \(Formatters.time.string(from: e.end))"
}

/// Day header label for an event, e.g. "Today", "Tomorrow", "Friday", "Mar 12".
func dayHeader(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
    let days = calendar.dateComponents([.day],
        from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: day)).day ?? 0
    switch days {
    case 0:  return "Today"
    case 1:  return "Tomorrow"
    case 2...6: return Formatters.weekday.string(from: day)
    default:    return Formatters.weekdayDate.string(from: day)
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
    case 2...6: dayPart = Formatters.weekday.string(from: due)
    default:    dayPart = Formatters.shortDate.string(from: due)
    }
    if hasTime { return "\(dayPart) \(Formatters.time.string(from: due))" }
    return dayPart
}

/// The new-event form's contents, sent to Google Calendar on Create.
struct EventDraft {
    var title = ""
    var start = EventDraft.nextHalfHour()
    var minutes = 60
    var allDay = false
    var calendarID = ""
    var location = ""
    var notes = ""
    var guests: [String] = []
    var sendInvites = true
    var addMeet = false
    var reminders: [GoogleCalendar.Reminder] = []
    /// Until the user changes them, reminders follow the chosen calendar's defaults.
    var remindersEdited = false
    var repeatRule: RepeatRule = .never
    var colorID: Int?
    /// All-day events can span several days.
    var days = 1
    /// Set when this draft edits an existing Google event instead of making one.
    var editing: GoogleCalendar.ExistingEvent?

    var end: Date {
        allDay ? Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
               : start.addingTimeInterval(Double(minutes) * 60)
    }

    var event: GoogleCalendar.NewEvent {
        let day = Calendar.current.startOfDay(for: start)
        return GoogleCalendar.NewEvent(
            calendarID: calendarID,
            title: title.trimmingCharacters(in: .whitespaces),
            start: allDay ? day : start,
            end: allDay ? Calendar.current.date(byAdding: .day, value: days, to: day) ?? day : end,
            allDay: allDay,
            location: location.trimmingCharacters(in: .whitespaces),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            guests: guests, sendInvites: sendInvites, addMeet: addMeet,
            reminders: reminders, recurrence: repeatRule.rrule(for: start), colorID: colorID)
    }

    /// A draft holding an existing event's current values.
    init(editing e: GoogleCalendar.ExistingEvent) {
        let cal = Calendar.current
        title = e.title
        start = e.start
        allDay = e.allDay
        if e.allDay {
            days = max(1, cal.dateComponents([.day], from: e.start, to: e.end).day ?? 1)
        } else {
            minutes = max(5, Int(e.end.timeIntervalSince(e.start) / 60))
        }
        calendarID = e.calendarID
        location = e.location
        notes = e.notes
        guests = e.guestEmails
        // Changes reach guests by email only when asked to.
        sendInvites = false
        addMeet = e.hasMeet
        reminders = e.reminders ?? []
        colorID = e.colorID
        editing = e
    }

    init() {}

    static func nextHalfHour(after d: Date = Date()) -> Date {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        let m = c.minute ?? 0
        c.minute = 0
        let hour = cal.date(from: c) ?? d
        return cal.date(byAdding: .minute, value: m < 30 ? 30 : 60, to: hour) ?? d
    }
}

enum RepeatRule: CaseIterable {
    case never, daily, weekdays, weekly, monthly, yearly

    func title(for start: Date) -> String {
        switch self {
        case .never:    return "Does not repeat"
        case .daily:    return "Every day"
        case .weekdays: return "Every weekday"
        case .weekly:   return "Every \(Formatters.weekday.string(from: start))"
        case .monthly:  return "Monthly on day \(Calendar.current.component(.day, from: start))"
        case .yearly:   return "Every year on \(Formatters.shortDate.string(from: start))"
        }
    }

    func rrule(for start: Date) -> String? {
        let days = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        switch self {
        case .never:    return nil
        case .daily:    return "RRULE:FREQ=DAILY"
        case .weekdays: return "RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
        case .weekly:   return "RRULE:FREQ=WEEKLY;BYDAY=\(days[Calendar.current.component(.weekday, from: start) - 1])"
        case .monthly:  return "RRULE:FREQ=MONTHLY"
        case .yearly:   return "RRULE:FREQ=YEARLY"
        }
    }
}

extension GoogleCalendar.Reminder {
    /// "10 min before", "1 day before", "At start".
    var label: String {
        guard minutes > 0 else { return "At start" }
        let (n, unit): (Int, String) =
            minutes % 10080 == 0 ? (minutes / 10080, "week")
            : minutes % 1440 == 0 ? (minutes / 1440, "day")
            : minutes % 60 == 0 ? (minutes / 60, "hr")
            : (minutes, "min")
        return "\(n) \(unit)\(n > 1 && unit != "min" && unit != "hr" ? "s" : "") before"
    }
}
