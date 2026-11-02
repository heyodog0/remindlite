// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import AppKit
import CryptoKit
import Network
import Security

/// Talks to the Google Calendar API for the two things Calendar.app's CalDAV
/// sync (and so EventKit) can't do: read per-event colors, and create or edit
/// events with guests, a Meet link and Google's own reminders. Everything else still
/// comes from EventKit.
///
/// Setup is the user's own Google Cloud "Desktop app" OAuth client (its JSON,
/// picked once via the menu-bar menu). Sign-in uses the standard loopback flow
/// with PKCE; the refresh token lives in a private file (see TokenFile).
@MainActor
final class GoogleCalendar {
    /// The color Google shows for each event, keyed with `key(uid:start:)`: its
    /// own color (colorId), else its event label's color. Events with neither
    /// keep their calendar's color and aren't in here.
    private(set) var colors: [String: NSColor] = [:]

    var isConnected: Bool { refreshToken != nil && client != nil }
    /// Whether this sign-in may create events. Sign-ins from before event
    /// creation existed were read-only and need one reconnect.
    var canCreate: Bool { isConnected && grantedScopes.contains(Self.eventsScope) }

    private var grantedScopes: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "googleScopes") ?? []) {
        didSet { UserDefaults.standard.set(Array(grantedScopes), forKey: "googleScopes") }
    }

    private struct Client: Codable { let client_id: String; let client_secret: String }
    private var client: Client? = GoogleCalendar.loadClient()
    private var refreshToken: String? = TokenFile.read()
    private var accessToken: (token: String, expires: Date)?

    private static let readScope = "https://www.googleapis.com/auth/calendar.readonly"
    private static let eventsScope = "https://www.googleapis.com/auth/calendar.events"
    private static let folder = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RemindLite")
    private static var clientURL: URL { folder.appendingPathComponent("google-client.json") }

    /// Google Calendar's event palette (the colors its UI shows for colorId 1–11).
    static let palette: [Int: NSColor] = [
        1: hex(0x7986CB), 2: hex(0x33B679), 3: hex(0x8E24AA), 4: hex(0xE67C73),
        5: hex(0xF6BF26), 6: hex(0xF4511E), 7: hex(0x039BE5), 8: hex(0x616161),
        9: hex(0x3F51B5), 10: hex(0x0B8043), 11: hex(0xD50000),
    ]

    /// Events match on iCalUID (EKEvent.calendarItemExternalIdentifier) plus
    /// start, since a recurring series shares one UID.
    /// A nil start keys a one-off event by UID alone: its color still matches
    /// while a move has reached Google but not yet EventKit (or the reverse).
    static func key(uid: String, start: Date?) -> String {
        // Calendar.app tags a recurring series' modified copies with
        // "/RID=<recurrence id>"; Google's iCalUID never has it.
        let base = uid.range(of: "/RID=").map { String(uid[..<$0.lowerBound]) } ?? uid
        guard let start else { return base }
        return "\(base)|\(Int((start.timeIntervalSince1970 / 60).rounded()))"
    }

    // MARK: connect / disconnect

    /// Pick the downloaded OAuth client JSON, then sign in in the browser.
    func connect() async throws {
        if client == nil {
            let panel = NSOpenPanel()
            panel.title = "Choose your Google OAuth client file"
            panel.message = "The JSON downloaded from Google Cloud ▸ Clients (Desktop app)."
            panel.allowedContentTypes = [.json]
            NSApp.activate(ignoringOtherApps: true)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let data = try Data(contentsOf: url)
            // Google's file nests the fields under "installed".
            struct File: Codable { let installed: Client }
            client = try JSONDecoder().decode(File.self, from: data).installed
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(client).write(to: Self.clientURL, options: .atomic)
        }
        guard let client else { return }
        try await signIn(client)
    }

    func disconnect() {
        refreshToken = nil; accessToken = nil; colors = [:]; grantedScopes = []
        TokenFile.delete()
    }

    // MARK: colors

    /// Re-read the colored events in [start, end) across all the account's
    /// calendars. Quietly leaves the old map in place on any failure.
    func refreshColors(from start: Date, to end: Date) async {
        guard isConnected, let token = try? await validAccessToken() else { return }
        var map: [String: NSColor] = [:]
        var uidCount: [String: Int] = [:]
        var byUID: [String: NSColor] = [:]
        let iso = ISO8601DateFormatter()
        do {
            let list: CalendarList = try await get(
                "users/me/calendarList?minAccessRole=reader&fields=items(id)", token)
            for cal in list.items {
                let id = cal.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cal.id
                // Event labels ("Event labels" in Google Calendar settings) are
                // defined per calendar; an event points at one by id.
                let labels: [String: NSColor] = ((try? await get(
                    "calendars/\(id)?fields=labelProperties", token) as CalendarLabels)?
                    .labelProperties?.eventLabels ?? [])
                    .reduce(into: [:]) { m, l in m[l.id] = Self.color(hex: l.backgroundColor) }
                let events: EventList = try await get(
                    "calendars/\(id)/events?singleEvents=true&maxResults=500"
                    + "&timeMin=\(iso.string(from: start))&timeMax=\(iso.string(from: end))"
                    + "&fields=items(iCalUID,colorId,eventLabelId,start)", token)
                for e in events.items {
                    uidCount[e.iCalUID, default: 0] += 1
                    let color = e.colorId.flatMap(Int.init).flatMap { Self.palette[$0] }
                        ?? e.eventLabelId.flatMap { labels[$0] }
                    guard let color, let s = e.start.resolved else { continue }
                    let key = Self.key(uid: e.iCalUID, start: s)
                    map[key] = color
                    byUID[e.iCalUID] = color
                }
            }
            // UID-only keys for events that occur once in the window.
            for (uid, color) in byUID where uidCount[uid] == 1 { map[Self.key(uid: uid, start: nil)] = color }
            colors = map
        } catch {
            NSLog("RemindLite: Google colors refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: live changes

    /// An event as Google has it right now, for showing changes before
    /// Calendar.app's own CalDAV sync brings them into EventKit.
    struct LiveEvent {
        let uid: String              // iCalUID, as EKEvent.calendarItemExternalIdentifier
        /// The slot an occurrence of a repeating series was scheduled in; nil
        /// for a one-off event.
        let originalStart: Date?
        let cancelled: Bool
        let calendarTitle: String
        let title: String
        let start: Date?
        let end: Date?
        let allDay: Bool
        let location: String?
        let notes: String?
        let updated: Date
    }

    private var readable: (calendars: [(id: String, title: String)], fetched: Date)?

    /// Events in [from, to) changed on Google since `since`, across all the
    /// account's calendars — including deletions.
    func changes(since: Date, from: Date, to: Date) async throws -> [LiveEvent] {
        let token = try await validAccessToken()
        if readable.map({ Date().timeIntervalSince($0.fetched) > 600 }) ?? true {
            struct List: Decodable {
                let items: [Item]
                struct Item: Decodable { let id: String; let summary: String; let summaryOverride: String? }
            }
            let list: List = try await get(
                "users/me/calendarList?minAccessRole=reader&fields=items(id,summary,summaryOverride)", token)
            readable = (list.items.map { ($0.id, $0.summaryOverride ?? $0.summary) }, Date())
        }
        let iso = ISO8601DateFormatter()
        var out: [LiveEvent] = []
        for cal in readable?.calendars ?? [] {
            let id = cal.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cal.id
            let data = try await getData(
                "calendars/\(id)/events?singleEvents=true&showDeleted=true&maxResults=250"
                + "&updatedMin=\(iso.string(from: since))"
                + "&timeMin=\(iso.string(from: from))&timeMax=\(iso.string(from: to))"
                + "&fields=items(id,iCalUID,status,summary,start,end,location,description,"
                + "originalStartTime,recurringEventId,updated)", token)
            guard let items = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"]
                    as? [[String: Any]] else { continue }
            for item in items {
                // Deleted events come back bare; Google's own events use
                // "<event id>@google.com" as their iCalUID.
                let base = item["recurringEventId"] as? String ?? item["id"] as? String ?? ""
                let uid = item["iCalUID"] as? String ?? "\(base)@google.com"
                let updated = (item["updated"] as? String).flatMap { Self.iso(fractional: $0) } ?? Date()
                out.append(LiveEvent(
                    uid: uid,
                    originalStart: Self.date(item["originalStartTime"]),
                    cancelled: item["status"] as? String == "cancelled",
                    calendarTitle: cal.title,
                    title: item["summary"] as? String ?? "",
                    start: Self.date(item["start"]), end: Self.date(item["end"]),
                    allDay: (item["start"] as? [String: Any])?["date"] != nil,
                    location: item["location"] as? String,
                    notes: item["description"] as? String,
                    updated: updated))
            }
        }
        return out
    }

    private static func iso(fractional s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    // MARK: creating events

    /// A calendar the account can add events to.
    struct WritableCalendar: Identifiable, Equatable {
        let id: String
        let title: String
        let color: NSColor
        let isPrimary: Bool
        let defaultReminders: [Reminder]
    }

    /// One Google reminder: a notification or an email, some minutes before.
    struct Reminder: Hashable, Codable {
        enum Method: String, Codable { case popup, email }
        var method: Method
        var minutes: Int
    }

    struct NewEvent {
        var calendarID: String
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        var location: String
        var notes: String
        var guests: [String]          // emails
        var sendInvites: Bool
        var addMeet: Bool
        var reminders: [Reminder]
        var recurrence: String?       // an RRULE, e.g. "RRULE:FREQ=WEEKLY;BYDAY=TH"
        var colorID: Int?             // 1–11, nil = the calendar's color
    }

    func writableCalendars() async throws -> [WritableCalendar] {
        let token = try await validAccessToken()
        let list: WritableList = try await get(
            "users/me/calendarList?minAccessRole=writer"
            + "&fields=items(id,summary,summaryOverride,backgroundColor,primary,defaultReminders)", token)
        return list.items.map {
            WritableCalendar(id: $0.id, title: $0.summaryOverride ?? $0.summary,
                             color: $0.backgroundColor.flatMap(Self.color(hex:)) ?? .systemBlue,
                             isPrimary: $0.primary ?? false,
                             defaultReminders: $0.defaultReminders ?? [])
        }
        .sorted { ($0.isPrimary ? 0 : 1, $0.title.localizedLowercase)
                < ($1.isPrimary ? 0 : 1, $1.title.localizedLowercase) }
    }

    /// Create the event; Google emails the guests when `sendInvites` is on.
    func create(_ e: NewEvent) async throws {
        let token = try await validAccessToken()
        var body: [String: Any] = [
            "summary": e.title,
            "start": when(e.start, allDay: e.allDay),
            "end": when(e.end, allDay: e.allDay),
            "reminders": ["useDefault": false,
                          "overrides": e.reminders.map { ["method": $0.method.rawValue,
                                                          "minutes": $0.minutes] }],
        ]
        if !e.location.isEmpty { body["location"] = e.location }
        if !e.notes.isEmpty { body["description"] = e.notes }
        if !e.guests.isEmpty { body["attendees"] = e.guests.map { ["email": $0] } }
        if let r = e.recurrence { body["recurrence"] = [r] }
        if let c = e.colorID { body["colorId"] = String(c) }
        if e.addMeet {
            body["conferenceData"] = ["createRequest": [
                "requestId": UUID().uuidString,
                "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
        }
        let id = e.calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? e.calendarID
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(id)/events"
            + "?conferenceDataVersion=1&sendUpdates=\(e.sendInvites ? "all" : "none")")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw GoogleError.http(data) }
    }

    // MARK: editing events

    /// An event as Google has it, found from the one EventKit shows.
    struct ExistingEvent {
        let calendarID: String
        let eventID: String
        /// One occurrence of a repeating series: edits change just that one.
        let isOccurrence: Bool
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let location: String
        let notes: String
        /// Google's attendee objects, kept whole so RSVPs survive a save.
        let attendees: [[String: Any]]
        let hasMeet: Bool
        /// nil when the event uses its calendar's default reminders.
        let reminders: [Reminder]?
        let colorID: Int?
        /// Only the organizer (or guests the organizer allowed) can change the
        /// event for everyone.
        let canModify: Bool

        /// Guests as editable emails: everyone but you and meeting rooms.
        var guestEmails: [String] {
            attendees.filter { $0["self"] as? Bool != true && $0["resource"] as? Bool != true }
                .compactMap { ($0["email"] as? String)?.lowercased() }
        }
    }

    /// The Google event behind an EventKit event: the same iCalUID, starting at
    /// the same time, on a calendar this account can write to. The one on the
    /// calendar EventKit shows it under wins when several copies exist.
    func findEvent(uid: String, start: Date, calendarTitle: String,
                   in calendars: [WritableCalendar]) async throws -> ExistingEvent? {
        let token = try await validAccessToken()
        let base = uid.range(of: "/RID=").map { String(uid[..<$0.lowerBound]) } ?? uid
        let iso = ISO8601DateFormatter()
        let ordered = calendars.filter { $0.title == calendarTitle } + calendars.filter { $0.title != calendarTitle }
        let want = Self.key(uid: base, start: start)
        for cal in ordered {
            let id = cal.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cal.id
            let q = base.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? base
            let data = try await getData(
                "calendars/\(id)/events?iCalUID=\(q)&singleEvents=true&maxResults=50"
                + "&timeMin=\(iso.string(from: start.addingTimeInterval(-86_400)))"
                + "&timeMax=\(iso.string(from: start.addingTimeInterval(86_400)))", token)
            guard let items = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"]
                    as? [[String: Any]] else { continue }
            for item in items where item["status"] as? String != "cancelled" {
                guard let s = Self.date(item["start"]), let e = Self.date(item["end"]),
                      Self.key(uid: base, start: s) == want, let eventID = item["id"] as? String
                else { continue }
                let allDay = (item["start"] as? [String: Any])?["date"] != nil
                let reminders = item["reminders"] as? [String: Any]
                let overrides: [Reminder]? = reminders?["useDefault"] as? Bool == true ? nil
                    : ((reminders?["overrides"] as? [[String: Any]]) ?? []).compactMap {
                        guard let m = ($0["method"] as? String).flatMap(Reminder.Method.init),
                              let min = $0["minutes"] as? Int else { return nil }
                        return Reminder(method: m, minutes: min)
                    }
                let organizerIsMe = (item["organizer"] as? [String: Any])?["self"] as? Bool == true
                let conference = item["conferenceData"] as? [String: Any]
                let solution = (conference?["conferenceSolution"] as? [String: Any])?["key"] as? [String: Any]
                return ExistingEvent(
                    calendarID: cal.id, eventID: eventID,
                    isOccurrence: item["recurringEventId"] != nil,
                    title: item["summary"] as? String ?? "",
                    start: s, end: e, allDay: allDay,
                    location: item["location"] as? String ?? "",
                    notes: item["description"] as? String ?? "",
                    attendees: item["attendees"] as? [[String: Any]] ?? [],
                    hasMeet: solution?["type"] as? String == "hangoutsMeet",
                    reminders: overrides,
                    colorID: (item["colorId"] as? String).flatMap(Int.init),
                    canModify: organizerIsMe || item["guestsCanModify"] as? Bool == true)
            }
        }
        return nil
    }

    /// Save the edited fields over `old`. Reminders go out only when
    /// `remindersChanged`, so an event on calendar defaults stays on them.
    func update(_ old: ExistingEvent, to e: NewEvent, remindersChanged: Bool) async throws {
        let token = try await validAccessToken()
        var body: [String: Any] = [
            "summary": e.title,
            "start": when(e.start, allDay: e.allDay),
            "end": when(e.end, allDay: e.allDay),
            "location": e.location,
            "description": e.notes,
            "colorId": e.colorID.map { String($0) as Any } ?? NSNull(),
        ]
        if remindersChanged {
            body["reminders"] = ["useDefault": false,
                                 "overrides": e.reminders.map { ["method": $0.method.rawValue,
                                                                 "minutes": $0.minutes] }]
        }
        // Keep each remaining guest's original entry (and its RSVP); add new
        // ones by email. You and meeting rooms always stay.
        let wanted = Set(e.guests)
        var attendees = old.attendees.filter {
            $0["self"] as? Bool == true || $0["resource"] as? Bool == true
                || wanted.contains(($0["email"] as? String)?.lowercased() ?? "")
        }
        let had = Set(old.attendees.compactMap { ($0["email"] as? String)?.lowercased() })
        attendees += e.guests.filter { !had.contains($0) }.map { ["email": $0] }
        if Set(old.guestEmails) != wanted { body["attendees"] = attendees }
        if !old.isOccurrence { body["recurrence"] = e.recurrence.map { [$0] } ?? [] }
        if e.addMeet && !old.hasMeet {
            body["conferenceData"] = ["createRequest": [
                "requestId": UUID().uuidString,
                "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
        } else if !e.addMeet && old.hasMeet {
            body["conferenceData"] = NSNull()
        }
        let cal = old.calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? old.calendarID
        let id = old.eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? old.eventID
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(cal)/events/\(id)"
            + "?conferenceDataVersion=1&sendUpdates=\(e.sendInvites ? "all" : "none")")!)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw GoogleError.http(data) }
    }

    /// A Google start/end object as a date (all-day: local midnight).
    private static func date(_ obj: Any?) -> Date? {
        guard let o = obj as? [String: Any] else { return nil }
        return EventList.When(dateTime: o["dateTime"] as? String, date: o["date"] as? String).resolved
    }

    /// Google's start/end: a date for all-day events, else a time in this zone.
    private func when(_ d: Date, allDay: Bool) -> [String: String] {
        if allDay {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
            return ["date": f.string(from: d)]
        }
        let f = ISO8601DateFormatter(); f.timeZone = .current
        return ["dateTime": f.string(from: d), "timeZone": TimeZone.current.identifier]
    }

    private struct WritableList: Decodable {
        let items: [Item]
        struct Item: Decodable {
            let id: String
            let summary: String
            let summaryOverride: String?
            let backgroundColor: String?
            let primary: Bool?
            let defaultReminders: [Reminder]?
        }
    }

    private struct CalendarList: Decodable { let items: [Item]; struct Item: Decodable { let id: String } }
    private struct CalendarLabels: Decodable {
        let labelProperties: Properties?
        struct Properties: Decodable { let eventLabels: [Label]? }
        struct Label: Decodable { let id: String; let backgroundColor: String }
    }
    private struct EventList: Decodable {
        let items: [Event]
        struct Event: Decodable {
            let iCalUID: String
            let colorId: String?
            let eventLabelId: String?
            let start: When
        }
        struct When: Decodable {
            let dateTime: String?   // timed: RFC 3339 with offset
            let date: String?       // all-day: "2026-10-31"

            /// All-day dates resolve to local midnight, as EventKit reports them.
            var resolved: Date? {
                if let dateTime { return ISO8601DateFormatter().date(from: dateTime) }
                guard let date else { return nil }
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
                return f.date(from: date)
            }
        }
    }

    private func get<T: Decodable>(_ path: String, _ token: String) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await getData(path, token))
    }

    private func getData(_ path: String, _ token: String) async throws -> Data {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/" + path)!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw GoogleError.http(data) }
        return data
    }

    // MARK: OAuth (loopback + PKCE)

    enum GoogleError: LocalizedError {
        case http(Data), noCode, cancelled
        var errorDescription: String? {
            switch self {
            case .http(let d):
                // Google's error body: {"error": {"message": "..."}}
                struct Body: Decodable { struct E: Decodable { let message: String }; let error: E }
                return (try? JSONDecoder().decode(Body.self, from: d))?.error.message
                    ?? String(data: d, encoding: .utf8) ?? "HTTP error"
            case .noCode:      return "Google didn't return a sign-in code"
            case .cancelled:   return "Sign-in was cancelled"
            }
        }
    }

    private func signIn(_ client: Client) async throws {
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomURLSafe(24)
        let receiver = try LoopbackReceiver()
        let redirect = "http://127.0.0.1:\(try await receiver.start())"

        var auth = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        auth.queryItems = [
            .init(name: "client_id", value: client.client_id),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "\(Self.readScope) \(Self.eventsScope)"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),   // always issue a refresh token
        ]
        NSWorkspace.shared.open(auth.url!)

        let query = try await receiver.waitForCallback()
        guard query["state"] == state, let code = query["code"] else {
            throw query["error"] != nil ? GoogleError.cancelled : GoogleError.noCode
        }
        let token = try await tokenRequest([
            "code": code, "client_id": client.client_id, "client_secret": client.client_secret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        if let r = token.refresh_token { refreshToken = r; TokenFile.write(r) }
        grantedScopes = Set((token.scope ?? "").split(separator: " ").map(String.init))
        accessToken = (token.access_token, Date().addingTimeInterval(Double(token.expires_in) - 60))
    }

    private func validAccessToken() async throws -> String {
        if let a = accessToken, a.expires > Date() { return a.token }
        guard let client, let refreshToken else { throw GoogleError.noCode }
        let token = try await tokenRequest([
            "client_id": client.client_id, "client_secret": client.client_secret,
            "refresh_token": refreshToken, "grant_type": "refresh_token",
        ])
        accessToken = (token.access_token, Date().addingTimeInterval(Double(token.expires_in) - 60))
        return token.access_token
    }

    private struct Token: Decodable {
        let access_token: String; let expires_in: Int; let refresh_token: String?; let scope: String?
    }

    private func tokenRequest(_ form: [String: String]) async throws -> Token {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents(); body.queryItems = form.map { .init(name: $0.key, value: $0.value) }
        req.httpBody = body.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw GoogleError.http(data) }
        return try JSONDecoder().decode(Token.self, from: data)
    }

    private static func loadClient() -> Client? {
        guard let data = try? Data(contentsOf: clientURL) else { return nil }
        return try? JSONDecoder().decode(Client.self, from: data)
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return Data(b).base64URL
    }

    /// "#7cb342" → NSColor.
    private static func color(hex: String) -> NSColor? {
        guard let v = Int(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else { return nil }
        return Self.hex(v)
    }

    private static func hex(_ v: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot HTTP listener on 127.0.0.1 that catches the OAuth redirect.
private final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private var portCont: CheckedContinuation<UInt16, Error>?
    private var queryCont: CheckedContinuation<[String: String], Error>?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            portCont = cont
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.portCont?.resume(returning: self.listener.port?.rawValue ?? 0); self.portCont = nil
                case .failed(let e): self.portCont?.resume(throwing: e); self.portCont = nil
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: .main)
        }
    }

    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { queryCont = $0 }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first,
                  let target = line.split(separator: " ").dropFirst().first,
                  let comps = URLComponents(string: "http://127.0.0.1" + target),
                  comps.queryItems?.isEmpty == false else { conn.cancel(); return }
            let page = "<html><body style='font:16px -apple-system;padding:40px'>"
                + "RemindLite is connected to Google Calendar. You can close this tab.</body></html>"
            let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n" + page
            conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in conn.cancel() })
            var q: [String: String] = [:]
            for item in comps.queryItems ?? [] { q[item.name] = item.value ?? "" }
            self.listener.cancel()
            self.queryCont?.resume(returning: q); self.queryCont = nil
        }
    }
}

/// The Google refresh token, in a file only this user can read. Not the
/// Keychain: its access list pins the exact build, so a self-signed app asks for
/// the login password after every update.
private enum TokenFile {
    private static let url = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("RemindLite/google-token")

    static func read() -> String? {
        (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func write(_ s: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(s.utf8),
                                       attributes: [.posixPermissions: 0o600])
    }

    static func delete() { try? FileManager.default.removeItem(at: url) }
}
