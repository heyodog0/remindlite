// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import SwiftUI
import AppKit

/// New-event form for the Calendar tab, also used to edit an event. Events are
/// created and edited in Google Calendar (not EventKit) so they can carry guests
/// with email invites, a Meet link and Google's own reminders; changes then
/// reach the list through Calendar.app's sync.
struct EventComposer: View {
    @EnvironmentObject var state: AppState
    @State private var innerHeight: CGFloat = 0
    private let scrollCap: CGFloat = 470

    private var editing: Bool { state.editingEvent }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if state.googleCanCreate && state.loadingEventEdit {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else if state.googleCanCreate {
                ScrollView {
                    form
                        .padding(.bottom, 4)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { innerHeight = $0 }
                }
                .scrollEdges()
                .frame(height: min(innerHeight, scrollCap))
            } else {
                connectCard
            }
        }
        .padding(.top, 12)
    }

    private var header: some View {
        ZStack {
            Text(editing ? "Edit Event" : "New Event").font(.system(size: 14, weight: .semibold))
            HStack {
                Button { withAnimation(Motion.screen) { state.cancelNewEvent() } } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("Back").font(.system(size: 13))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                if state.googleCanCreate {
                    Button { state.createEvent() } label: {
                        Group {
                            if state.creatingEvent {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text(editing ? "Save" : "Create").font(.system(size: 13, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(height: 26).padding(.horizontal, 14)
                        .background(Capsule().fill(Color.blue.opacity(state.canCreateDraft ? 0.85 : 0.3)))
                    }
                    .buttonStyle(.plain).disabled(!state.canCreateDraft)
                }
            }
        }
    }

    private var connectCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "calendar.badge.plus").font(.system(size: 24)).foregroundStyle(.secondary)
            Text(state.googleConnected
                 ? "Reconnect Google Calendar to let RemindLite create and edit events."
                 : "Connect Google Calendar to create and edit events with guests, Meet links and reminders.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { state.connectGoogle() } label: {
                Text(state.googleConnected ? "Reconnect" : "Connect Google")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(height: 28).padding(.horizontal, 16)
                    .background(Capsule().fill(pillFill()))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 18)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let e = state.eventDraft.editing, !e.canModify {
                note("person.crop.circle.badge.exclamationmark",
                     "You're a guest here: only the organizer can change this event for everyone.")
            }
            TitleCard()
            WhenCard()
            CalendarCard()
            GuestsCard()
            RemindersCard()
            DetailsCard()
            if let error = state.composeError {
                Text(error)
                    .font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func note(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 11)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

// MARK: - cards

private let cardShape = RoundedRectangle(cornerRadius: 10, style: .continuous)

private extension View {
    func card() -> some View {
        padding(.vertical, 8).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardShape.fill(.white.opacity(0.05)))
            .overlay(cardShape.strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
    }
}

/// A label on the left, a control on the right.
private struct FormRow<Trailing: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            trailing()
        }
        .frame(minHeight: 22)
    }
}

/// The title, and a chip offering any date/time typed into it
/// ("Lunch with Sam Thu 1pm" → Thursday 1:00 PM).
private struct TitleCard: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Title", text: $state.eventDraft.title, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
                .lineLimit(1...3)
                .focused($focused)
                .onSubmit { state.createEvent() }
            if let found = TypedTime(in: state.eventDraft.title) {
                Button { found.apply(to: &state.eventDraft) } label: {
                    Label("Use \(found.summary)", systemImage: "wand.and.stars")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.blue.opacity(0.25)))
                }
                .buttonStyle(.plain)
                .help("Set the time from the title and remove it from the title")
            }
        }
        .card()
        .onAppear { focused = true }
    }
}

private struct WhenCard: View {
    @EnvironmentObject var state: AppState
    @State private var pickingDay = false
    private static let durations = [15, 30, 45, 60, 90, 120, 180, 240]

    private var draft: Binding<EventDraft> { $state.eventDraft }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FormRow(title: "All day", icon: "sun.max") {
                Toggle("", isOn: draft.allDay).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            FormRow(title: "Date", icon: "calendar") {
                Button { pickingDay = true } label: {
                    Text(Formatters.weekdayDate.string(from: state.eventDraft.start))
                        .font(.system(size: 12))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $pickingDay, arrowEdge: .bottom) {
                    DatePicker("", selection: dayBinding, displayedComponents: [.date])
                        .datePickerStyle(.graphical).labelsHidden()
                        .padding(10)
                }
            }
            if state.eventDraft.allDay {
                FormRow(title: "Length", icon: "hourglass") {
                    Menu {
                        ForEach(1...14, id: \.self) { d in
                            Button(d == 1 ? "1 day" : "\(d) days") { state.eventDraft.days = d }
                        }
                    } label: {
                        Text(state.eventDraft.days == 1 ? "1 day" : "\(state.eventDraft.days) days")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            } else {
                FormRow(title: "Starts", icon: "clock") {
                    TimeField(date: draft.start)
                }
                FormRow(title: "Length", icon: "hourglass") {
                    Menu {
                        ForEach(Self.durations, id: \.self) { m in
                            Button(Self.durationLabel(m)) { state.eventDraft.minutes = m }
                        }
                    } label: {
                        Text("\(Self.durationLabel(state.eventDraft.minutes)) · until \(Formatters.time.string(from: state.eventDraft.end))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            if state.eventDraft.editing?.isOccurrence == true {
                FormRow(title: "Repeat", icon: "repeat") {
                    Text("Changes this one only").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else {
                FormRow(title: "Repeat", icon: "repeat") {
                    Menu {
                        ForEach(RepeatRule.allCases, id: \.self) { r in
                            Button(r.title(for: state.eventDraft.start)) { state.eventDraft.repeatRule = r }
                        }
                    } label: {
                        Text(state.eventDraft.repeatRule.title(for: state.eventDraft.start))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
        }
        .card()
    }

    /// Changing the day keeps the chosen time of day.
    private var dayBinding: Binding<Date> {
        Binding(get: { state.eventDraft.start }, set: { day in
            let cal = Calendar.current
            let t = cal.dateComponents([.hour, .minute], from: state.eventDraft.start)
            var c = cal.dateComponents([.year, .month, .day], from: day)
            c.hour = t.hour; c.minute = t.minute
            if let d = cal.date(from: c) { state.eventDraft.start = d }
            pickingDay = false
        })
    }

    static func durationLabel(_ m: Int) -> String {
        m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) hr" : String(format: "%.1f hr", Double(m) / 60)
    }
}

/// Which Google calendar the event goes on, and an optional event color.
private struct CalendarCard: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FormRow(title: "Calendar", icon: "tray") {
                if state.eventDraft.editing != nil {
                    // Moving an event between calendars isn't offered.
                    HStack(spacing: 5) {
                        Circle().fill(Color(nsColor: state.draftCalendar?.color ?? .secondaryLabelColor))
                            .frame(width: 8, height: 8)
                        Text(state.draftCalendar?.title ?? "")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1).frame(maxWidth: 140, alignment: .trailing)
                    }
                } else {
                    Menu {
                        CheckmarkItems(state.googleCalendars.map { ($0.id, $0.title) },
                                       selected: state.eventDraft.calendarID) { state.selectEventCalendar($0) }
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(Color(nsColor: state.draftCalendar?.color ?? .secondaryLabelColor))
                                .frame(width: 8, height: 8)
                            Text(state.draftCalendar?.title ?? "Loading…")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .lineLimit(1).frame(maxWidth: 140, alignment: .trailing)
                        }
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                }
            }
            // Google's event palette; the first dot is "use the calendar's color".
            HStack(spacing: 0) {
                swatch(nil, state.draftCalendar?.color ?? .secondaryLabelColor)
                ForEach(1...11, id: \.self) { id in
                    swatch(id, GoogleCalendar.palette[id] ?? .gray)
                }
            }
        }
        .card()
    }

    private func swatch(_ id: Int?, _ color: NSColor) -> some View {
        let on = state.eventDraft.colorID == id
        return Button { state.eventDraft.colorID = id } label: {
            Circle().fill(Color(nsColor: color))
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.white.opacity(on ? 0.9 : 0), lineWidth: 1.5))
                .overlay {
                    if id == nil {
                        Image(systemName: "slash.circle").font(.system(size: 9)).foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(id == nil ? "Calendar color" : "Event color")
    }
}

/// Guests as removable chips, typed in by email with suggestions from people
/// already on your events.
private struct GuestsCard: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @FocusState private var focused: Bool

    private var suggestions: [(email: String, name: String)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return state.knownGuests
            .filter { !state.eventDraft.guests.contains($0.email)
                && ($0.email.contains(q) || $0.name.lowercased().contains(q)) }
            .prefix(4).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "person.2").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Add guests", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .focused($focused)
                    .onSubmit { add(suggestions.first?.email ?? query) }
                    .onChange(of: query) { _, q in
                        // A comma or space ends an address.
                        if let last = q.last, last == "," || last == " ",
                           q.contains("@") { add(String(q.dropLast())) }
                    }
            }
            ForEach(suggestions, id: \.email) { s in
                Button { add(s.email) } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.name).font(.system(size: 12)).lineLimit(1)
                        if s.name != s.email {
                            Text(s.email).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !state.eventDraft.guests.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(state.eventDraft.guests, id: \.self) { email in
                        Chip(text: name(for: email)) {
                            state.eventDraft.guests.removeAll { $0 == email }
                        }
                        .help(email)
                    }
                }
                FormRow(title: state.eventDraft.editing == nil ? "Email invites" : "Email guests the changes",
                        icon: "paperplane") {
                    Toggle("", isOn: $state.eventDraft.sendInvites)
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
            }
            FormRow(title: "Google Meet", icon: "video") {
                Toggle("", isOn: $state.eventDraft.addMeet)
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
        }
        .card()
    }

    private func name(for email: String) -> String {
        state.knownGuests.first { $0.email == email }.map(\.name) ?? email
    }

    private func add(_ raw: String) {
        let email = raw.trimmingCharacters(in: CharacterSet(charactersIn: " ,;<>")).lowercased()
        guard email.contains("@"), email.contains("."), !email.contains(" ") else { return }
        if !state.eventDraft.guests.contains(email) { state.eventDraft.guests.append(email) }
        query = ""
        focused = true
    }
}

/// Google's reminders for this event: notifications and emails, each some time
/// before. Starts as the calendar's defaults.
private struct RemindersCard: View {
    @EnvironmentObject var state: AppState
    private static let presets = [0, 5, 10, 15, 30, 60, 120, 1440, 2880, 10080]
    private static let maxReminders = 5   // Google's limit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FormRow(title: "Reminders", icon: "bell") {
                if state.eventDraft.reminders.count < Self.maxReminders {
                    Menu {
                        Section("Notification") { items(.popup) }
                        Section("Email") { items(.email) }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            if state.eventDraft.reminders.isEmpty {
                Text("None").font(.system(size: 11)).foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 4) {
                    ForEach(state.eventDraft.reminders, id: \.self) { r in
                        Chip(text: r.label, icon: r.method == .email ? "envelope" : "bell") {
                            state.eventDraft.reminders.removeAll { $0 == r }
                            state.eventDraft.remindersEdited = true
                        }
                    }
                }
            }
        }
        .card()
    }

    @ViewBuilder
    private func items(_ method: GoogleCalendar.Reminder.Method) -> some View {
        ForEach(Self.presets, id: \.self) { m in
            let r = GoogleCalendar.Reminder(method: method, minutes: m)
            Button(r.label) {
                guard !state.eventDraft.reminders.contains(r) else { return }
                state.eventDraft.reminders.append(r)
                state.eventDraft.reminders.sort { $0.minutes < $1.minutes }
                state.eventDraft.remindersEdited = true
            }
        }
    }
}

private struct DetailsCard: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "mappin").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Location", text: $state.eventDraft.location)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.bottom, 7)
            Divider().opacity(0.2)
            TextField("Description", text: $state.eventDraft.notes, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(1...5)
                .padding(.top, 7)
        }
        .card()
    }
}

// MARK: - pieces

private struct Chip: View {
    let text: String
    var icon: String? = nil
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9)) }
            Text(text).font(.system(size: 11)).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 7).padding(.trailing, 6).padding(.vertical, 3)
        .background(Capsule().fill(.white.opacity(0.09)))
    }
}

/// Lays children out left to right, wrapping to new lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if !row.indices.isEmpty && row.width + spacing + size.width > width {
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

/// A time of day as one small pill. Clicking it opens a short popover: type a
/// time ("3", "3:30p", "1530", "noon") or pick from a scrolling list of
/// quarter hours, centered on the current one. Shared with the reminder editor.
struct TimeField: View {
    @Binding var date: Date
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Text(Formatters.time.string(from: date))
                .font(.system(size: 12).monospacedDigit())
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(.white.opacity(open ? 0.16 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            TimePopover(date: $date) { open = false }
        }
    }
}

private struct TimePopover: View {
    @Binding var date: Date
    let done: () -> Void
    @State private var typed = ""
    @FocusState private var focused: Bool
    private var cal: Calendar { .current }

    /// Minutes after midnight, every 15.
    private static let slots = Array(stride(from: 0, to: 24 * 60, by: 15))

    private var current: Int {
        let c = cal.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
    /// What's typed, else the current time: the row to highlight.
    private var target: Int { TypedClock.minutes(typed) ?? current }
    private var nearestSlot: Int { Self.slots.min { abs($0 - target) < abs($1 - target) } ?? 0 }

    var body: some View {
        VStack(spacing: 6) {
            TextField(Formatters.time.string(from: date), text: $typed)
                .textFieldStyle(.plain).font(.system(size: 12).monospacedDigit())
                .multilineTextAlignment(.center)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.08)))
                .focused($focused)
                .onSubmit { if let m = TypedClock.minutes(typed) { set(m) } }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Self.slots, id: \.self) { m in
                            let on = m == nearestSlot
                            Button { set(m) } label: {
                                Text(label(m))
                                    .font(.system(size: 12, weight: on ? .semibold : .regular).monospacedDigit())
                                    .foregroundStyle(on ? .white : .primary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 3)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.accentColor : .clear))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).id(m)
                        }
                    }
                }
                .scrollIndicators(.never)
                .onAppear { proxy.scrollTo(nearestSlot, anchor: .center) }
                .onChange(of: nearestSlot) { _, m in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(m, anchor: .center) }
                }
            }
            .frame(height: 150)
        }
        .padding(8)
        .frame(width: 112)
        .onAppear { focused = true }
    }

    private func label(_ m: Int) -> String {
        Formatters.time.string(from: cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: date) ?? date)
    }

    private func set(_ m: Int) {
        if let d = cal.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: date) { date = d }
        done()
    }
}

/// A typed time of day as minutes after midnight. Without am/pm, 1–6 read as
/// afternoon and 7–11 as morning — how plans are usually written.
enum TypedClock {
    static func minutes(_ raw: String) -> Int? {
        var s = raw.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ".", with: "")
        if s == "noon" { return 12 * 60 }
        if s == "midnight" { return 0 }
        var pm: Bool?
        for (suffix, isPM) in [("pm", true), ("am", false), ("p", true), ("a", false)] where s.hasSuffix(suffix) {
            pm = isPM; s.removeLast(suffix.count); break
        }
        var h: Int, m = 0
        if let colon = s.firstIndex(of: ":") {
            guard let hh = Int(s[..<colon]), let mm = Int(s[s.index(after: colon)...]) else { return nil }
            h = hh; m = mm
        } else {
            guard !s.isEmpty, s.count <= 4, let n = Int(s) else { return nil }
            if s.count <= 2 { h = n } else { h = n / 100; m = n % 100 }
        }
        guard (0...23).contains(h), (0...59).contains(m) else { return nil }
        if let pm {
            guard (1...12).contains(h) else { return nil }
            h = h % 12 + (pm ? 12 : 0)
        } else if (1...6).contains(h), !s.hasPrefix("0") {
            h += 12   // "3", "330", "3:30" → afternoon; "03:30" stays morning
        }
        return h * 60 + m
    }
}

/// A date or time typed into the title, found with NSDataDetector.
private struct TypedTime {
    let range: Range<String.Index>
    let date: Date
    let minutes: Int?
    /// "Thu 1pm" names a time; "Thursday" alone keeps the time already chosen.
    let hasTime: Bool

    init?(in title: String) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let date = match.date, let range = Range(match.range, in: title) else { return nil }
        let text = title[range].lowercased()
        self.range = range
        self.date = date
        self.minutes = match.duration > 0 ? Int(match.duration / 60) : nil
        self.hasTime = text.contains(where: \.isNumber) || text.contains("noon") || text.contains("midnight")
    }

    var summary: String {
        let day = Formatters.weekdayDate.string(from: date)
        return hasTime ? "\(day) · \(Formatters.time.string(from: date))" : day
    }

    func apply(to draft: inout EventDraft) {
        let cal = Calendar.current
        if hasTime {
            draft.start = date
            draft.allDay = false
        } else {
            let t = cal.dateComponents([.hour, .minute], from: draft.start)
            var c = cal.dateComponents([.year, .month, .day], from: date)
            c.hour = t.hour; c.minute = t.minute
            draft.start = cal.date(from: c) ?? draft.start
        }
        if let minutes { draft.minutes = minutes }
        var title = draft.title
        title.removeSubrange(range)
        // Drop the joining word the date leaves behind ("Lunch at", "Call on").
        title = title.replacingOccurrences(of: #"\s+(at|on|from|this|next)\s*$"#, with: "",
                                           options: [.regularExpression, .caseInsensitive])
        draft.title = title.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",-–")))
    }
}
