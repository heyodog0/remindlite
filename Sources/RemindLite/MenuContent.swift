import SwiftUI
import AppKit

struct MenuContent: View {
    @EnvironmentObject var state: AppState

    private let glassShape = RoundedRectangle(cornerRadius: 26, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            // Fixed header — measured once so the window knows the chrome height.
            // It lives outside the height-animated body, so it can never be
            // clipped or briefly overlaid during a transition.
            VStack(spacing: 0) {
                TabBar()
                Divider().opacity(0.35)
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                state.chromeHeight = h
            }

            bodyArea
        }
        .padding(12)
        .frame(width: panelWidth, alignment: .top)
        // The glass hugs the content and animates its own height with the body
        // (smooth toggles). The window grows under it.
        .background(GlassBackground().clipShape(glassShape))
        .overlay(glassShape.strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
        .clipShape(glassShape)
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .frame(maxWidth: .infinity, alignment: .top)
        // First time the Calendar tab is opened, ask for permission.
        .onChange(of: state.tab) { _, newTab in
            if newTab == .calendar && state.calendarAccess == .unknown {
                state.requestCalendarAccess()
            }
        }
    }

    /// The body below the header: the active screen, cross-fading + scaling from
    /// the top, with its frame height animated to the current screen's natural
    /// height (measured by the hidden probe). Clipped so the outgoing screen
    /// doesn't spill while shorter — and crucially this clip excludes the header.
    private var bodyArea: some View {
        ZStack(alignment: .top) {
            activeScreen
        }
        .animation(.easeInOut(duration: 0.3), value: state.editingID)
        .animation(.easeInOut(duration: 0.3), value: state.tab)
        .animation(.easeInOut(duration: 0.3), value: state.showingListFilter)
        .animation(.easeInOut(duration: 0.3), value: state.showingCalendarFilter)
        .frame(height: state.screenHeight > 0 ? state.screenHeight : nil, alignment: .top)
        .clipped()
        .animation(.easeInOut(duration: 0.3), value: state.screenHeight)
        // Hidden, instantly-swapping copy reports the current screen's natural
        // height (no cross-fade union), without affecting layout.
        .background(alignment: .top) {
            ZStack(alignment: .top) { activeScreen }
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                    state.reportScreenHeight(h)
                }
        }
    }

    /// The screen for the current (tab, editingID) state. Used twice — once
    /// visible (cross-faded + scaled) and once hidden to measure its height.
    /// Each branch carries the transition so insert/remove animates.
    @ViewBuilder
    private var activeScreen: some View {
        // Plain cross-fade: the incoming screen fades in, the outgoing one fades
        // out quickly. (No scale — scaling the incoming list made the rows grow
        // in, which read as a subtle wobble.)
        let move = AnyTransition.asymmetric(
            insertion: .opacity,
            removal: .opacity.animation(.easeOut(duration: 0.12)))
        if state.tab == .reminders {
            if state.showingListFilter {
                ListFilter().transition(move)
            } else if state.editingID != nil {
                TaskDetail()
                    .transition(move)
            } else {
                accessGate(state.access, denied: "Reminders access is off",
                           prompt: "Show your reminders here") { TaskList() }
                    .transition(move)
            }
        } else if state.showingCalendarFilter {
            CalendarFilter().transition(move)
        } else {
            accessGate(state.calendarAccess, denied: "Calendar access is off",
                       prompt: "Show your events here") { EventList() }
                .transition(move)
        }
    }

    @ViewBuilder
    private func accessGate<Content: View>(_ access: RemindersStore.Access,
                                           denied: String, prompt: String,
                                           @ViewBuilder content: () -> Content) -> some View {
        switch access {
        case .granted: content()
        case .denied:  AccessMessage(tab: state.tab, denied: true)
        case .unknown: AccessMessage(tab: state.tab, denied: false)
        }
    }
}

/// Segmented Reminders / Calendar switch — the blue pill slides between the two
/// (matchedGeometryEffect) — plus a context-aware "open app" button.
private struct TabBar: View {
    @EnvironmentObject var state: AppState
    @Namespace private var pill
    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    private var filterAvailable: Bool {
        state.tab == .calendar ? state.calendarAccess == .granted
                               : state.access == .granted
    }
    private var filterOn: Bool {
        state.tab == .calendar ? state.showingCalendarFilter : state.showingListFilter
    }
    private var groupMode: GroupMode {
        state.tab == .calendar ? state.eventGroupMode : state.groupMode
    }
    private func setGroup(_ m: GroupMode) {
        if state.tab == .calendar { state.eventGroupMode = m } else { state.groupMode = m }
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(PanelTab.allCases) { t in
                    TabSegment(tab: t, selected: state.tab == t, namespace: pill) {
                        // The pill slides (its own .animation below), the content
                        // cross-fades, and the window eases to the new height — all
                        // keyed off state.tab, so they move together.
                        state.tab = t
                    }
                }
            }
            .padding(2)
            .background(shape.fill(.white.opacity(0.06)))
            .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.8))
            .animation(.easeInOut(duration: 0.22), value: state.tab)

            // Group by date (due date / day) or by container (list / calendar).
            // A plain toggle (not a menu): two modes, so one click switches. Fixed
            // width keeps the calendar↔list glyph swap from nudging the row.
            if filterAvailable {
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        setGroup(groupMode == .date ? .entity : .date)
                    }
                } label: {
                    Image(systemName: groupMode == .entity ? "list.bullet.indent" : "calendar")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(state.tab == .calendar
                      ? (groupMode == .entity ? "Grouped by calendar — click for by day"
                                              : "Grouped by day — click for by calendar")
                      : (groupMode == .entity ? "Grouped by list — click for by date"
                                              : "Grouped by date — click for by list"))
            }

            // Filter: choose which lists (Reminders) or calendars (Calendar) show.
            if filterAvailable {
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        if state.tab == .calendar { state.showingCalendarFilter.toggle() }
                        else { state.showingListFilter.toggle() }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(filterOn ? Color.accentColor : .secondary)
                .help(state.tab == .calendar ? "Choose calendars" : "Choose lists")
            }

            Button {
                state.tab == .reminders ? state.openRemindersApp() : state.openCalendarApp()
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(state.tab == .reminders ? "Open Reminders" : "Open Calendar")
        }
        .padding(.bottom, 8)
    }
}

private struct TabSegment: View {
    let tab: PanelTab
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    private let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

    var body: some View {
        Button(action: action) {
            // Glyph only: keeps the segments compact next to the three trailing
            // controls (the text was wrapping/truncating when squeezed).
            Image(systemName: tab.icon)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    // The single shared pill — matchedGeometryEffect slides it
                    // from one segment to the other when `selected` moves.
                    if selected {
                        shape.fill(LinearGradient(colors: [.blue, .blue.opacity(0.82)],
                                                  startPoint: .top, endPoint: .bottom))
                            .matchedGeometryEffect(id: "tabPill", in: namespace)
                    }
                }
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(tab.title)
    }
}

private struct TaskList: View {
    @EnvironmentObject var state: AppState
    private let scrollCap: CGFloat = 420   // scroll past this; below it the panel hugs content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if state.sections.isEmpty && state.completedItems.isEmpty {
                        EmptyState()
                    }
                    ForEach(state.sections) { section in
                        Section(title: section.title, accent: section.accent,
                                items: section.items)
                    }
                    if !state.completedItems.isEmpty {
                        CompletedSection(items: state.completedItems)
                    }
                }
                .padding(.vertical, 10)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { state.listInnerHeight = $0 }
            }
            .frame(height: min(state.listInnerHeight, scrollCap))

            Divider().opacity(0.35)
            AddField().padding(.top, 8)
        }
    }
}

private struct Section: View {
    let title: String
    let accent: Color
    let items: [TaskItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(accent)
                .padding(.horizontal, 4)
            ForEach(items) { item in
                TaskRow(item: item)
            }
        }
    }
}

/// Completed-today, collapsed by default behind a "Completed · N" disclosure so
/// it never crowds out the open tasks.
private struct CompletedSection: View {
    @EnvironmentObject var state: AppState
    let items: [TaskItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                state.showCompleted.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(state.showCompleted ? 90 : 0))
                        .animation(.easeInOut(duration: 0.18), value: state.showCompleted)
                    Text("COMPLETED · \(items.count)")
                        .font(.system(size: 10, weight: .bold))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if state.showCompleted {
                ForEach(items) { item in
                    TaskRow(item: item)
                }
            }
        }
    }
}

private struct TaskRow: View {
    @EnvironmentObject var state: AppState
    let item: TaskItem
    @State private var hovering = false

    private var done: Bool { state.isCompleted(item) }
    // Only surface the list when there's more than one to distinguish.
    private var showList: Bool { state.reminderLists.count > 1 && !item.listName.isEmpty }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            // The circle completes / un-completes the task.
            Button {
                state.toggle(item)
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(done ? .blue : .secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Tapping the title/body opens the editor (notes, date, …).
            Button {
                state.beginEdit(item)
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        if let pri = priorityMarks(item.priority) {
                            Text(pri.text).font(.system(size: 11, weight: .bold))
                                .foregroundStyle(pri.color)
                        }
                        Text(item.title)
                            .font(.system(size: 13))
                            .strikethrough(done, color: .secondary)
                            .foregroundStyle(done ? .secondary : .primary)
                            .lineLimit(2)
                    }
                    // Metadata line: list (dot + name, when more than one list) and
                    // due label, joined by a dot separator.
                    if showList || dueLabel(item.due, hasTime: item.hasTime) != nil {
                        HStack(spacing: 5) {
                            if showList {
                                Circle().fill(item.listColor).frame(width: 6, height: 6)
                                Text(item.listName)
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let label = dueLabel(item.due, hasTime: item.hasTime) {
                                if showList {
                                    Text("·").font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Text(label)
                                    .font(.system(size: 11))
                                    .foregroundStyle(bucket(for: item.due) == .overdue ? .red : .secondary)
                            }
                        }
                    }
                    if let notes = item.notes, !notes.isEmpty {
                        Text(notes)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Delete — appears on hover (always available via right-click too).
            Button {
                state.delete(item)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red.opacity(0.9))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Delete reminder")
        }
        .padding(.vertical, 5).padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(done ? 0.55 : 1)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(role: .destructive) { state.delete(item) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct AddField: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool
    @FocusState private var notesFocused: Bool

    private func submit() {
        guard !state.draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        state.add()
        focused = true                // keep focus to add another
    }

    var body: some View {
        VStack(spacing: 0) {
            titleRow
            // .identity → no fade; the notes block is revealed purely by the panel
            // growing (the bodyArea clip), which avoids the opacity flash.
            if state.showDraftNotes { notesBlock.transition(.identity) }
        }
        .padding(.vertical, 7).padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder((focused || notesFocused) ? .blue.opacity(0.5) : .white.opacity(0.12), lineWidth: 0.8))
        // Always-measure the notes block (hidden) so the first toggle animates to a
        // known height instead of snapping.
        .background(alignment: .top) {
            notesMeasure
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    state.draftNotesRowHeight = $0
                }
        }
        // Tapping anywhere in the pill focuses the title field (bigger hit target).
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        // Press Escape to dismiss the cursor (resign focus) without closing the panel.
        .onExitCommand { focused = false; notesFocused = false }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            TextField("Add a reminder…", text: $state.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit { submit() }

            // Which list the new reminder is filed into (remembers the choice).
            if state.reminderLists.count > 1 { listMenu }

            // Toggle an inline notes field for the new reminder (animated grow).
            // Don't auto-focus it: focusing mid-grow attaches the text field editor
            // before layout settles (a stray flash nearby) and flips the border blue
            // (the opacity flash). Click the field to type — cursor on demand.
            Button {
                withAnimation(.easeInOut(duration: 0.3)) { state.showDraftNotes.toggle() }
            } label: {
                Image(systemName: state.showDraftNotes ? "note.text" : "note.text.badge.plus")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(state.showDraftNotes ? Color.accentColor : .secondary)
            .help(state.showDraftNotes ? "Hide notes" : "Add notes")
        }
    }

    private var notesBlock: some View {
        VStack(spacing: 6) {
            Divider().opacity(0.15)
            TextField("Notes", text: $state.draftNotes)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .focused($notesFocused)
                .onSubmit { submit() }
        }
        .padding(.top, 6)
    }

    /// Layout-identical, non-interactive copy of `notesBlock` for height probing.
    private var notesMeasure: some View {
        VStack(spacing: 6) {
            Divider().opacity(0.15)
            TextField("Notes", text: .constant(""))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.top, 6)
    }

    /// Compact list chooser: a colored dot + name that opens a checkmarked menu.
    private var listMenu: some View {
        Menu {
            ForEach(state.reminderLists) { list in
                Button { state.newListID = list.id } label: {
                    if state.newListID == list.id {
                        Label(list.title, systemImage: "checkmark")
                    } else {
                        Text(list.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Circle().fill(state.listOption(state.newListID)?.color ?? .secondary)
                    .frame(width: 8, height: 8)
                Text(state.listOption(state.newListID)?.title ?? "List")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).frame(maxWidth: 80)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Task editor — title, notes, due date, and priority. Shown in place of the
/// reminders list when a task is tapped.
private struct TaskDetail: View {
    @EnvironmentObject var state: AppState
    private let field = RoundedRectangle(cornerRadius: 10, style: .continuous)
    private let pickShape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    private var canSave: Bool {
        !state.editTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // Animate a due/time toggle only when the destination height is already
    // known (cached); otherwise apply it instantly. A cached change resizes the
    // panel in lockstep with the content (smooth); an unknown one would have to
    // animate a measured-a-frame-late height, which teleports — so snap instead.
    private func setToggle(targetCached: Bool, _ change: @escaping () -> Void) {
        if targetCached {
            withAnimation(.easeInOut(duration: 0.3), change)
        } else {
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx, change)
        }
    }

    private var dueBinding: Binding<Bool> {
        Binding(get: { state.editHasDue }, set: { newVal in
            setToggle(targetCached: state.editorHeightCached(due: newVal, time: state.editHasTime)) {
                state.editHasDue = newVal
            }
        })
    }

    private var timeBinding: Binding<Bool> {
        Binding(get: { state.editHasTime }, set: { newVal in
            setToggle(targetCached: state.editorHeightCached(due: state.editHasDue, time: newVal)) {
                state.editHasTime = newVal
            }
        })
    }

    // MARK: due-date helpers
    private var cal: Calendar { .current }
    private var today: Date { cal.startOfDay(for: Date()) }
    private var tomorrow: Date { cal.date(byAdding: .day, value: 1, to: today) ?? today }
    private var nextWeek: Date { cal.date(byAdding: .day, value: 7, to: today) ?? today }

    /// Set the due day, keeping the current time-of-day so the Time toggle stays
    /// meaningful.
    private func pick(_ day: Date) {
        let t = cal.dateComponents([.hour, .minute], from: state.editDue)
        var c = cal.dateComponents([.year, .month, .day], from: day)
        c.hour = t.hour ?? 9; c.minute = t.minute ?? 0
        if let d = cal.date(from: c) { state.editDue = d }
    }

    private func isPicked(_ day: Date) -> Bool { cal.isDate(state.editDue, inSameDayAs: day) }

    @ViewBuilder
    private func quickPick(_ title: String, _ day: Date) -> some View {
        let on = isPicked(day)
        Button { pick(day) } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .foregroundStyle(on ? Color.white : .primary)
                .background(pickShape.fill(on ? Color.blue.opacity(0.85) : .white.opacity(0.06)))
                .overlay(pickShape.strokeBorder(.white.opacity(on ? 0 : 0.10), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    // Time as plain dropdowns — no clock to drag, no editable digit field. Each
    // menu writes back into editDue's hour/minute.
    private var hourBinding: Binding<Int> {
        Binding(get: {
            let h = cal.component(.hour, from: state.editDue) % 12
            return h == 0 ? 12 : h
        }, set: { setTime(hour12: $0) })
    }
    private var minuteBinding: Binding<Int> {
        Binding(get: { (cal.component(.minute, from: state.editDue) / 5) * 5 },
                set: { setTime(minute: $0) })
    }
    private var isPMBinding: Binding<Bool> {
        Binding(get: { cal.component(.hour, from: state.editDue) >= 12 },
                set: { setTime(pm: $0) })
    }

    private func setTime(hour12: Int? = nil, minute: Int? = nil, pm: Bool? = nil) {
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: state.editDue)
        let curHour = c.hour ?? 9
        let cur12 = { let x = curHour % 12; return x == 0 ? 12 : x }()
        let h12 = hour12 ?? cur12
        let newPM = pm ?? (curHour >= 12)
        var h24 = h12 % 12
        if newPM { h24 += 12 }
        c.hour = h24
        c.minute = minute ?? c.minute
        if let d = cal.date(from: c) { state.editDue = d }
    }

    /// The due-on content (quick picks, calendar, divider, Time toggle) — minus
    /// the time row. Reused for the visible section and for the hidden height
    /// measurement, so both are identical.
    private var dueContentBlock: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                quickPick("Today", today)
                quickPick("Tomorrow", tomorrow)
                quickPick("Next Week", nextWeek)
            }
            DatePicker("", selection: $state.editDue, displayedComponents: [.date])
                .datePickerStyle(.graphical)
                .labelsHidden()
                .tint(.blue)

            Divider().opacity(0.15)

            HStack {
                Label("Time", systemImage: "clock")
                    .font(.system(size: 13))
                Spacer()
                Toggle("", isOn: timeBinding)
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
        }
    }

    private var timeRow: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            Picker("", selection: hourBinding) {
                ForEach(1...12, id: \.self) { Text("\($0)").tag($0) }
            }.labelsHidden().fixedSize()
            Text(":").foregroundStyle(.secondary)
            Picker("", selection: minuteBinding) {
                ForEach(Array(stride(from: 0, through: 55, by: 5)), id: \.self) {
                    Text(String(format: "%02d", $0)).tag($0)
                }
            }.labelsHidden().fixedSize()
            Picker("", selection: isPMBinding) {
                Text("AM").tag(false)
                Text("PM").tag(true)
            }.labelsHidden().fixedSize()
            Spacer(minLength: 0)
        }
        .pickerStyle(.menu)
        .font(.system(size: 12))
        .frame(maxWidth: .infinity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(alignment: .center) {
                Button { state.cancelEdit() } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button { state.saveEdit() } label: {
                    Text("Save")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(height: 26)                 // fixed height ⇒ text dead-centered
                        .padding(.horizontal, 16)
                        .background(Capsule().fill(Color.blue.opacity(canSave ? 0.85 : 0.3)))
                }
                .buttonStyle(.plain).disabled(!canSave)
            }

            // Title + notes
            VStack(spacing: 0) {
                TextField("Title", text: $state.editTitle, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 14, weight: .semibold))
                    .lineLimit(1...3)
                    .padding(.vertical, 8).padding(.horizontal, 10)
                Divider().opacity(0.2)
                TextField("Notes", text: $state.editNotes, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1...4)
                    .padding(.vertical, 8).padding(.horizontal, 10)
            }
            .background(field.fill(.white.opacity(0.05)))
            .overlay(field.strokeBorder(.white.opacity(0.08), lineWidth: 0.8))

            // List — which Reminders list this task lives in (move it here).
            if state.reminderLists.count > 1 {
                HStack {
                    Label("List", systemImage: "list.bullet")
                        .font(.system(size: 13))
                    Spacer()
                    Menu {
                        ForEach(state.reminderLists) { list in
                            Button { state.editListID = list.id } label: {
                                if state.editListID == list.id {
                                    Label(list.title, systemImage: "checkmark")
                                } else {
                                    Text(list.title)
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Circle().fill(state.listOption(state.editListID)?.color ?? .secondary)
                                .frame(width: 8, height: 8)
                            Text(state.listOption(state.editListID)?.title ?? "List")
                                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                .padding(.vertical, 9).padding(.horizontal, 10)
                .background(field.fill(.white.opacity(0.05)))
                .overlay(field.strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
            }

            // Due date — quick picks, an inline month calendar (tap a day; no
            // editable digit fields, no stuck highlight), and a dropdown time
            // chooser (no clock to drag).
            VStack(spacing: 8) {
                HStack {
                    Label("Due Date", systemImage: "calendar")
                        .font(.system(size: 13))
                    Spacer()
                    // Cache-aware toggle: smooth when the height is known, instant
                    // the first time (no teleport). Keeps the content + panel height
                    // in lockstep so the section fades/collapses cleanly.
                    Toggle("", isOn: dueBinding)
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                if state.editHasDue {
                    dueContentBlock
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                            state.dueContentHeight = $0
                        }
                    if state.editHasTime {
                        timeRow
                    }
                }
            }
            .padding(.vertical, 9).padding(.horizontal, 10)
            .background(field.fill(.white.opacity(0.05)))
            .overlay(field.strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
            // Measure the section pieces even while hidden, so the *first* toggle
            // of Due Date or Time already knows the height delta and animates
            // (instead of snapping). The time row is tiny; the due-content block
            // (with its calendar) is only measured hidden while Due Date is off —
            // when it's on, we read the height from the visible block above.
            .background {
                ZStack {
                    timeRow
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                            state.timeRowHeight = $0
                        }
                    if !state.editHasDue {
                        dueContentBlock
                            .fixedSize(horizontal: false, vertical: true)
                            .hidden()
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                                state.dueContentHeight = $0
                            }
                    }
                }
            }

            // Priority
            Picker("", selection: $state.editPriority) {
                Text("None").tag(0)
                Text("Low").tag(9)
                Text("Medium").tag(5)
                Text("High").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()

            Button { state.deleteEditing() } label: {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.plain).foregroundStyle(.red)
            .background(field.fill(.red.opacity(0.10)))
        }
        // Breathing room so the Back/Save header isn't cramped against the chrome
        // divider above it (matches the filter screens' header spacing).
        .padding(.top, 12)
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 26)).foregroundStyle(.green.opacity(0.85))
            Text("All clear").font(.system(size: 13, weight: .medium))
            Text("No open reminders").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

private struct AccessMessage: View {
    @EnvironmentObject var state: AppState
    let tab: PanelTab
    let denied: Bool

    private var noun: String { tab == .reminders ? "Reminders" : "Calendar" }
    private var thing: String { tab == .reminders ? "reminders" : "events" }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.circle")
                .font(.system(size: 30)).foregroundStyle(.secondary)
            Text(denied ? "\(noun) access is off" : "Show your \(thing) here")
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
            Text(denied
                 ? "Enable RemindLite under Privacy & Security ▸ \(noun)."
                 : "RemindLite needs permission to read your \(noun).")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ActionButton(title: denied ? "Open Settings" : "Grant Access",
                         systemImage: denied ? "gearshape" : "checkmark.shield") {
                if denied { state.openPrivacySettings(tab) }
                else if tab == .reminders { state.requestAccess() }
                else { state.requestCalendarAccess() }
            }
        }
        .padding(.vertical, 20).padding(.horizontal, 8)
    }
}

/// Shared header for the filter screens: a back button pinned left with the
/// title truly centered (ZStack, so the back button's width can't shove it off).
private struct FilterHeader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("Back").font(.system(size: 13))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

/// Per-calendar visibility filter for the Calendar tab. Lists every event
/// calendar (grouped by account) with a toggle; hidden ones are excluded from
/// the event fetch. EventKit has no visibility API, so the choice is RemindLite's
/// own, persisted in AppState.
private struct CalendarFilter: View {
    @EnvironmentObject var state: AppState
    private let scrollCap: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FilterHeader(title: "Calendars") {
                withAnimation(.easeInOut(duration: 0.3)) { state.showingCalendarFilter = false }
            }
            .padding(.vertical, 12)
            Divider().opacity(0.35)

            if state.eventCalendars.isEmpty {
                Text("No calendars found")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(accounts, id: \.self) { account in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(account.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 2)
                                ForEach(state.eventCalendars.filter { $0.account == account }) { cal in
                                    FilterRow(option: cal, shown: state.isCalendarShown(cal.id),
                                              toggle: { state.toggleCalendar(cal.id) },
                                              onColorPick: { c in state.setCalendarColor(cal.id, c) })
                                }
                            }
                        }
                    }
                    .padding(.top, 10).padding(.bottom, 4)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                        state.calendarFilterInnerHeight = $0
                    }
                }
                .frame(height: min(state.calendarFilterInnerHeight, scrollCap))
            }
        }
        .padding(.top, 2)
    }

    /// Account names in first-seen order (calendars are already account-sorted).
    private var accounts: [String] {
        var seen = Set<String>(); var order: [String] = []
        for c in state.eventCalendars where seen.insert(c.account).inserted { order.append(c.account) }
        return order
    }
}

/// One toggle row in a filter screen (a calendar or a reminder list). Shared by
/// CalendarFilter and ListFilter. When `onColorPick` is set (reminder lists), the
/// leading dot is tappable to recolor the list; the rest toggles visibility.
private struct FilterRow: View {
    let option: CalendarOption
    let shown: Bool
    let toggle: () -> Void
    var onColorPick: ((NSColor) -> Void)? = nil
    @State private var pickingColor = false

    var body: some View {
        HStack(spacing: 9) {
            if let onColorPick {
                Button { pickingColor = true } label: {
                    Circle().fill(option.color).frame(width: 12, height: 12)
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Change color")
                .popover(isPresented: $pickingColor, arrowEdge: .leading) {
                    ColorPalette { c in onColorPick(c); pickingColor = false }
                }
            } else {
                Circle().fill(option.color).frame(width: 10, height: 10)
            }

            Button(action: toggle) {
                HStack(spacing: 9) {
                    Text(option.title).font(.system(size: 13)).lineLimit(1)
                        .foregroundStyle(shown ? .primary : .secondary)
                    Spacer(minLength: 8)
                    Image(systemName: shown ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(shown ? Color.blue : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5).padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.white.opacity(0.04)))
    }
}

/// A small grid of preset list colors, shown in a popover from a list's dot.
private struct ColorPalette: View {
    let pick: (NSColor) -> Void
    private let colors: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemMint,
        .systemTeal, .systemCyan, .systemBlue, .systemIndigo, .systemPurple,
        .systemPink, .systemBrown, .systemGray]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 10), count: 5),
                  spacing: 10) {
            ForEach(colors.indices, id: \.self) { i in
                Button { pick(colors[i]) } label: {
                    Circle().fill(Color(nsColor: colors[i])).frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 188)
        .environment(\.colorScheme, .dark)
    }
}

/// Per-list visibility filter for the Reminders tab — same shape as CalendarFilter
/// but over reminder lists. Hidden lists are excluded from the reminder fetch.
private struct ListFilter: View {
    @EnvironmentObject var state: AppState
    private let scrollCap: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FilterHeader(title: "Lists") {
                withAnimation(.easeInOut(duration: 0.3)) { state.showingListFilter = false }
            }
            .padding(.vertical, 12)
            Divider().opacity(0.35)

            if state.reminderLists.isEmpty {
                Text("No lists found")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(accounts, id: \.self) { account in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(account.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 2)
                                ForEach(state.reminderLists.filter { $0.account == account }) { list in
                                    FilterRow(option: list, shown: state.isListShown(list.id),
                                              toggle: { state.toggleList(list.id) },
                                              onColorPick: { c in state.setListColor(list.id, c) })
                                }
                            }
                        }
                    }
                    .padding(.top, 10).padding(.bottom, 4)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                        state.reminderListFilterInnerHeight = $0
                    }
                }
                .frame(height: min(state.reminderListFilterInnerHeight, scrollCap))
            }

            newListComposer
                .padding(.top, 12)
        }
        .padding(.top, 2)
        .animation(.snappy(duration: 0.2), value: state.listError)
    }

    /// Create a new reminder list — name field + (when >1 account) a source picker.
    private var newListComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                TextField("New list…", text: $state.newListName)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .onSubmit { state.createList() }
                if state.reminderSources.count > 1 { sourceMenu }
            }
            .padding(.vertical, 7).padding(.horizontal, 9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.8))

            if let err = state.listError {
                Text(err).font(.system(size: 11)).foregroundStyle(.orange)
                    .transition(.opacity)
            }
        }
    }

    /// Which account a new list is created in (iCloud, On My Mac, …).
    private var sourceMenu: some View {
        Menu {
            ForEach(state.reminderSources) { src in
                Button { state.newListSourceID = src.id } label: {
                    if state.newListSourceID == src.id {
                        Label(src.title, systemImage: "checkmark")
                    } else {
                        Text(src.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(state.reminderSources.first { $0.id == state.newListSourceID }?.title ?? "Account")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).frame(maxWidth: 80)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private var accounts: [String] {
        var seen = Set<String>(); var order: [String] = []
        for c in state.reminderLists where seen.insert(c.account).inserted { order.append(c.account) }
        return order
    }
}

/// Calendar (events) list, grouped by day across the next week.
private struct EventList: View {
    @EnvironmentObject var state: AppState
    private let scrollCap: CGFloat = 440

    var body: some View {
        // By Calendar grouping spans days, so each row shows its own day.
        let byCalendar = state.eventGroupMode == .entity
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if state.eventSections.isEmpty {
                    NoEvents()
                }
                ForEach(state.eventSections) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.title.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(group.accent)
                            .padding(.horizontal, 4)
                        ForEach(group.items) { EventRow(event: $0, showDay: byCalendar) }
                    }
                }
            }
            .padding(.vertical, 10)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { state.eventInnerHeight = $0 }
        }
        .frame(height: min(state.eventInnerHeight, scrollCap))
    }
}

private struct EventRow: View {
    let event: EventItem
    var showDay: Bool = false

    private var timeLine: String {
        showDay ? "\(dayHeader(event.start)) · \(timeRange(event))" : timeRange(event)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(event.calendarColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13)).lineLimit(2)
                Text(timeLine)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let loc = event.location, !loc.isEmpty {
                    Label(loc, systemImage: "mappin")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.04)))
    }
}

private struct NoEvents: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 26)).foregroundStyle(.secondary)
            Text("Nothing scheduled").font(.system(size: 13, weight: .medium))
            Text("No events in the next week").font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
