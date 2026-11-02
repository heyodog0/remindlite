// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import SwiftUI

/// `--demo`: made-up reminders, events and a Now list for screenshots. Nothing
/// is read from or written to Reminders, Calendar, Google or the synced Now
/// file while it's on.
enum Demo {
    static let on = ProcessInfo.processInfo.arguments.contains("--demo")

    private static let cal = Calendar.current
    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        let d = cal.date(byAdding: .day, value: day, to: cal.startOfDay(for: Date()))!
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: d)!
    }

    static let lists = [
        CalendarOption(id: "personal", title: "Personal", color: .blue, account: "iCloud"),
        CalendarOption(id: "school", title: "School", color: .orange, account: "iCloud"),
        CalendarOption(id: "errands", title: "Errands", color: .green, account: "iCloud"),
    ]

    static let calendars = [
        CalendarOption(id: "me", title: "Personal", color: Color(red: 0.25, green: 0.45, blue: 0.95), account: "Google"),
        CalendarOption(id: "classes", title: "Classes", color: .orange, account: "Google"),
        CalendarOption(id: "lab", title: "Lab", color: .purple, account: "Google"),
    ]

    static var tasks: [TaskItem] {
        func t(_ id: String, _ title: String, _ due: Date?, time: Bool = false, list: Int,
               priority: Int = 0, notes: String? = nil, done: Bool = false) -> TaskItem {
            let l = lists[list]
            return TaskItem(id: id, externalID: id, title: title, due: due, hasTime: time, priority: priority,
                            notes: notes, completed: done, completionDate: done ? Date() : nil,
                            listID: l.id, listName: l.title, listColor: l.color)
        }
        return [
            t("r1", "Submit problem set 6", at(-1, 23, 59), time: true, list: 1, priority: 1),
            t("r2", "Email advisor about thesis meeting", at(0, 0), list: 0),
            t("r3", "Pick up dry cleaning", at(0, 17, 30), time: true, list: 2),
            t("r4", "Read chapter 4 for seminar", at(1, 0), list: 1, notes: "Pages 81–120"),
            t("r5", "Renew passport", at(3, 0), list: 0),
            t("r6", "Groceries: oat milk, eggs, spinach", nil, list: 2),
            t("r7", "Book flights home", nil, list: 0),
            t("r8", "Water the plants", at(0, 9), time: true, list: 0, done: true),
        ]
    }

    static var events: [EventItem] {
        func e(_ id: String, _ title: String, _ start: Date, minutes: Int, cal c: Int,
               location: String? = nil, meet: Bool = false, guests: [String] = []) -> EventItem {
            let k = calendars[c]
            let link = meet ? MeetingLink.find(in: ["https://meet.google.com/abc-defg-hij"]) : nil
            let attendees = guests.enumerated().map { i, n in
                Attendee(id: n, name: n, rsvp: i == 1 ? .pending : .accepted, isOrganizer: i == 0, isMe: false)
            }
            return EventItem(id: id, externalID: id, title: title, start: start,
                             end: start.addingTimeInterval(Double(minutes) * 60), isAllDay: false,
                             calendarID: k.id, calendarName: k.title, calendarColor: k.color,
                             location: location, notes: nil, url: nil, meeting: link,
                             organizer: guests.first, attendees: attendees, isCanceled: false)
        }
        // The first few follow the clock, so a screenshot at any hour shows
        // something happening now and soon.
        let hour = cal.dateInterval(of: .hour, for: Date())!.start
        func soon(_ h: Double) -> Date { hour.addingTimeInterval(h * 3600) }
        return [
            e("e1", "Lab meeting", soon(0), minutes: 60, cal: 2, meet: true,
              guests: ["Priya Patel", "Sam Lee", "Jordan Kim", "Alex Chen"]),
            e("e2", "Lunch with Sam", soon(1.5), minutes: 60, cal: 0, location: "Clover"),
            e("e3", "Machine Learning", soon(3), minutes: 75, cal: 1, location: "Science Center 101"),
            e("e5", "Gym", at(1, 7, 30), minutes: 60, cal: 0),
            e("e6", "Thesis check-in", at(1, 11), minutes: 30, cal: 2, meet: true,
              guests: ["Dr. Rivera", "Priya Patel"]),
            e("e7", "Dinner with Alex", at(1, 19), minutes: 90, cal: 0, location: "Pammy's"),
        ].sorted { $0.start < $1.start }
    }

    static let now: [NowEntry] = [
        .pin(tasks[1]),
        NowEntry(id: "q1", kind: .quick, title: "Reply to Jordan's slides", reminderID: nil, reminderUID: nil, done: true),
        NowEntry(id: "q2", kind: .quick, title: "Push the plotting fix", reminderID: nil, reminderUID: nil, done: false),
    ]
}

extension Demo {
    static let googleCalendars = [
        GoogleCalendar.WritableCalendar(id: "me", title: "Personal", color: NSColor(red: 0.25, green: 0.45, blue: 0.95, alpha: 1),
                                        isPrimary: true, defaultReminders: [.init(method: .popup, minutes: 10)]),
        GoogleCalendar.WritableCalendar(id: "lab", title: "Lab", color: .systemPurple,
                                        isPrimary: false, defaultReminders: []),
    ]
}
