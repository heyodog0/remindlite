// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import SwiftUI
import AppKit

struct MenuContent: View {
    @EnvironmentObject var state: AppState

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
        .padding(panelPadding)
        // Open/close: the content settles down into place inside the glass (the
        // glass itself fades with the window, never scaled — see StatusController).
        .opacity(state.panelVisible ? 1 : 0)
        .scaleEffect(state.panelVisible ? 1 : 0.97, anchor: .top)
        .offset(y: state.panelVisible ? 0 : -6)
        .frame(width: panelWidth, alignment: .top)
        // The glass hugs the content and animates its own height with the body
        // (smooth toggles). The window grows under it.
        .background(GlassBackground())
        .overlay(panelShape.strokeBorder(.white.opacity(0.08), lineWidth: 0.8))
        .clipShape(panelShape)
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
        .animation(Motion.screen, value: state.editingID)
        .animation(Motion.screen, value: state.tab)
        .animation(Motion.screen, value: state.showingListFilter)
        .animation(Motion.screen, value: state.showingCalendarFilter)
        .animation(Motion.screen, value: state.selectedEventID)
        .animation(Motion.screen, value: state.composingEvent)
        .frame(height: state.screenHeight > 0 ? state.screenHeight : nil, alignment: .top)
        .clipped()
        .animation(Motion.screen, value: state.screenHeight)
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
            removal: .opacity.animation(Motion.fadeOut))
        if state.tab == .reminders {
            if state.showingListFilter {
                ListFilter().transition(move)
            } else if state.editingID != nil {
                TaskDetail()
                    .transition(move)
            } else {
                accessGate(state.access) { TaskList() }
                    .transition(move)
            }
        } else if state.composingEvent {
            EventComposer().transition(move)
        } else if state.showingCalendarFilter {
            CalendarFilter().transition(move)
        } else if let event = state.selectedEvent {
            EventDetail(event: event).transition(move)
        } else {
            accessGate(state.calendarAccess) { EventList() }
                .transition(move)
        }
    }

    @ViewBuilder
    private func accessGate<Content: View>(_ access: RemindersStore.Access,
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
            .animation(Motion.quick, value: state.tab)

            // Group by date (due date / day) or by container (list / calendar).
            // A plain toggle (not a menu): two modes, so one click switches. Fixed
            // width keeps the calendar↔list glyph swap from nudging the row.
            if filterAvailable {
                Button {
                    withAnimation(Motion.quick) {
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
                    withAnimation(Motion.screen) {
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

            // New event (in Google Calendar, so it can invite people).
            if state.tab == .calendar && state.calendarAccess == .granted {
                Button {
                    withAnimation(Motion.screen) {
                        state.composingEvent ? state.cancelNewEvent() : state.beginNewEvent()
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(state.composingEvent ? Color.accentColor : .secondary)
                .help("New event")
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
                        shape.fill(pillFill())
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
                    NowSection()
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
            .scrollEdges()
            .frame(height: min(state.listInnerHeight, scrollCap))

            Divider().opacity(0.35)
            // Always-visible title + notes composer (no toggle, so no resize flash).
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
                        .animation(Motion.quick, value: state.showCompleted)
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
    /// Shown inside the Now section (hover offers unpin instead of delete).
    var inNow = false
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

            // Pin into Now — on hover, or always (filled) once pinned so you can
            // see what's already in this sitting's list.
            if !done || inNow {
                Button { state.togglePin(item) } label: {
                    Image(systemName: state.isPinned(item) ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(state.isPinned(item) ? Color.nowAccent : .secondary)
                }
                .buttonStyle(.plain)
                .opacity(hovering || (state.isPinned(item) && !inNow) ? 1 : 0)
                .help(state.isPinned(item) ? "Remove from Now" : "Do now")
            }

            // Delete — appears on hover (always available via right-click too).
            // Not inside Now, where a slip would delete the real reminder.
            if !inNow {
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
        }
        .padding(.vertical, 5).padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(done ? 0.55 : 1)
        .onHover { hovering = $0 }
        .contextMenu {
            Button { state.togglePin(item) } label: {
                state.isPinned(item) ? Label("Remove from Now", systemImage: "pin.slash")
                                     : Label("Do Now", systemImage: "pin")
            }
            Button(role: .destructive) { state.delete(item) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

extension Color {
    /// The Now section's accent (distinct from Overdue red / Today blue).
    static let nowAccent = Color.teal
}

/// "Now": this sitting's short checklist, above the due-date sections. Pinned
/// reminders (real, synced) mixed with quick items (local lines). Clear ends
/// the sitting; unfinished quick items can be kept as real reminders.
private struct NowSection: View {
    @EnvironmentObject var state: AppState
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(state.now.isEmpty ? "NOW" : "NOW · \(state.nowOpenCount) LEFT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.nowAccent)
                Spacer()
                if !state.now.isEmpty {
                    Button("Clear") {
                        if state.unfinishedQuickItems.isEmpty { state.clearNow(keepUnfinished: false) }
                        else { confirmingClear = true }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            if confirmingClear { clearConfirm }

            ForEach(state.visibleNow) { entry in
                if entry.kind == .pinned, let item = state.reminder(for: entry) {
                    TaskRow(item: item, inNow: true)
                } else {
                    NowQuickRow(entry: entry)
                }
            }

            if state.nowOpenCount > state.nowSoftCap {
                Text("That’s a lot for one sitting — pick the few that matter?")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                    .padding(.horizontal, 4)
            }

            NowAddRow()
        }
        .animation(Motion.quick, value: state.now)
        .animation(Motion.quick, value: confirmingClear)
        .onChange(of: state.now.isEmpty) { _, empty in if empty { confirmingClear = false } }
    }

    /// Inline (not a modal — a modal steals key and closes the panel).
    private var clearConfirm: some View {
        let n = state.unfinishedQuickItems.count
        return HStack(spacing: 6) {
            Text("\(n) unfinished").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Keep as reminders") {
                state.clearNow(keepUnfinished: true); confirmingClear = false
            }
            .buttonStyle(NowPillButton(tint: .blue))
            Button("Discard") {
                state.clearNow(keepUnfinished: false); confirmingClear = false
            }
            .buttonStyle(NowPillButton(tint: .red))
            Button { confirmingClear = false } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Cancel")
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
    }
}

/// A quick (local) Now line: tick it off, or on hover keep it as a real
/// reminder / remove it.
private struct NowQuickRow: View {
    @EnvironmentObject var state: AppState
    let entry: NowEntry
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Button { state.toggleNow(entry) } label: {
                Image(systemName: entry.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(entry.done ? Color.nowAccent : .secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(entry.title)
                .font(.system(size: 13))
                .strikethrough(entry.done, color: .secondary)
                .foregroundStyle(entry.done ? .secondary : .primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if !entry.done {
                    Button { state.keepAsReminder(entry) } label: {
                        Image(systemName: "tray.and.arrow.down")
                    }
                    .help("Keep as a reminder")
                }
                Button { state.removeNow(entry) } label: { Image(systemName: "xmark") }
                    .help("Remove")
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.vertical, 5).padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.nowAccent.opacity(0.06)))
        .opacity(entry.done ? 0.55 : 1)
        .onHover { hovering = $0 }
    }
}

/// One-line composer for quick Now items. Return adds and keeps focus, so you
/// can jot several in a row like a Notes checklist.
private struct NowAddRow: View {
    @EnvironmentObject var state: AppState
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.nowAccent)
                .frame(width: 15)
            TextField("Add for now…", text: $text)
                .textFieldStyle(.plain).font(.system(size: 12))
                .focused($focused)
                .onSubmit {
                    state.addNow(text); text = ""; focused = true
                }
                .onExitCommand { focused = false }
        }
        .padding(.vertical, 4).padding(.horizontal, 10)
    }
}

private struct NowPillButton: ButtonStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.28 : 0.16)))
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
        // Title + notes always visible — no toggle, so the panel never grows/shrinks
        // for notes and there's no resize flash at all.
        VStack(spacing: 0) {
            titleRow
            notesBlock
        }
        .padding(.vertical, 7).padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder((focused || notesFocused) ? .blue.opacity(0.5) : .white.opacity(0.12), lineWidth: 0.8))
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

    /// Compact list chooser: a colored dot + name that opens a checkmarked menu.
    private var listMenu: some View {
        Menu {
            CheckmarkItems(state.reminderLists.map { ($0.id, $0.title) },
                           selected: state.newListID) { state.newListID = $0 }
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
            withAnimation(Motion.screen, change)
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
        HStack {
            Spacer()
            TimeField(date: $state.editDue)
        }
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
                        CheckmarkItems(state.reminderLists.map { ($0.id, $0.title) },
                                       selected: state.editListID) { state.editListID = $0 }
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

/// Per-calendar visibility filter for the Calendar tab. Hidden calendars are
/// excluded from the event fetch. EventKit has no visibility API, so the choice
/// is RemindLite's own, persisted in AppState.
private struct CalendarFilter: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        FilterScreen(title: "Calendars",
                     onBack: { state.showingCalendarFilter = false },
                     options: state.eventCalendars, emptyText: "No calendars found",
                     innerHeight: $state.calendarFilterInnerHeight,
                     isShown: state.isCalendarShown, toggle: state.toggleCalendar,
                     setColor: state.setCalendarColor) { EmptyView() }
    }
}

/// The shared filter screen: a header, then every option grouped by account
/// with a visibility toggle (scrolling past a cap), then an optional footer.
private struct FilterScreen<Footer: View>: View {
    let title: String
    let onBack: () -> Void
    let options: [CalendarOption]
    let emptyText: String
    @Binding var innerHeight: CGFloat
    let isShown: (String) -> Bool
    let toggle: (String) -> Void
    let setColor: (String, NSColor) -> Void
    @ViewBuilder let footer: () -> Footer
    private let scrollCap: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FilterHeader(title: title) { withAnimation(Motion.screen, onBack) }
                .padding(.vertical, 12)
            Divider().opacity(0.35)

            if options.isEmpty {
                Text(emptyText)
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
                                ForEach(options.filter { $0.account == account }) { o in
                                    FilterRow(option: o, shown: isShown(o.id),
                                              toggle: { toggle(o.id) },
                                              onColorPick: { c in setColor(o.id, c) })
                                }
                            }
                        }
                    }
                    .padding(.top, 10).padding(.bottom, 4)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                        innerHeight = $0
                    }
                }
                .scrollEdges()
                .frame(height: min(innerHeight, scrollCap))
            }

            footer()
        }
        .padding(.top, 2)
    }

    /// Account names in first-seen order (options are already account-sorted).
    private var accounts: [String] {
        var seen = Set<String>(); var order: [String] = []
        for o in options where seen.insert(o.account).inserted { order.append(o.account) }
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

/// Per-list visibility filter for the Reminders tab — same screen as the
/// calendar filter, plus a composer for new lists. Hidden lists are excluded
/// from the reminder fetch.
private struct ListFilter: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        FilterScreen(title: "Lists",
                     onBack: { state.showingListFilter = false },
                     options: state.reminderLists, emptyText: "No lists found",
                     innerHeight: $state.reminderListFilterInnerHeight,
                     isShown: state.isListShown, toggle: state.toggleList,
                     setColor: state.setListColor) {
            newListComposer.padding(.top, 12)
        }
        .animation(Motion.quick, value: state.listError)
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
            CheckmarkItems(state.reminderSources.map { ($0.id, $0.title) },
                           selected: state.newListSourceID) { state.newListSourceID = $0 }
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
        .scrollEdges()
        .frame(height: min(state.eventInnerHeight, scrollCap))
    }
}

private struct EventRow: View {
    @EnvironmentObject var state: AppState
    let event: EventItem
    var showDay: Bool = false
    @State private var hovering = false

    private var timeLine: String {
        showDay ? "\(dayHeader(event.start)) · \(timeRange(event))" : timeRange(event)
    }

    /// The location line, unless it's just the call link (shown as Join).
    private var place: String? {
        guard let loc = event.location?.trimmingCharacters(in: .whitespaces), !loc.isEmpty,
              event.meeting.map({ !loc.contains($0.url.host ?? "") }) ?? true else { return nil }
        return loc
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(state.eventColor(event) ?? event.calendarColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13)).lineLimit(2)
                    .strikethrough(event.isCanceled, color: .secondary)
                Text(timeLine)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let place {
                    Label(place, systemImage: "mappin")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let link = event.meeting, !event.isCanceled {
                JoinButton(link: link, prominent: event.isJoinableNow)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.white.opacity(hovering ? 0.08 : 0.04)))
        .contentShape(Rectangle())
        // A tap gesture (not a Button) so the Join button inside stays its own target.
        .onTapGesture { withAnimation(Motion.screen) { state.selectedEventID = event.id } }
        .onHover { hovering = $0 }
        .opacity(event.isCanceled ? 0.55 : 1)
    }
}

extension EventItem {
    /// From 10 minutes before the start until the end — when Join matters.
    var isJoinableNow: Bool {
        let now = Date()
        return now >= start.addingTimeInterval(-10 * 60) && now < end
    }
}

/// Opens the event's video call. Prominent (a blue "Join" pill) when the call is
/// about to start or under way; otherwise a quiet camera glyph.
private struct JoinButton: View {
    @EnvironmentObject var state: AppState
    let link: MeetingLink
    var prominent: Bool
    var wide = false

    var body: some View {
        Button { state.openMeeting(link) } label: {
            if prominent || wide {
                Label(wide ? "Join \(link.service)" : "Join", systemImage: "video.fill")
                    .font(.system(size: wide ? 13 : 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: wide ? .infinity : nil)
                    .padding(.horizontal, 9).padding(.vertical, wide ? 8 : 3)
                    .background(Capsule().fill(pillFill()))
            } else {
                Image(systemName: "video")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .buttonStyle(.plain)
        .help("Join \(link.service)")
    }
}

/// Everything EventKit knows about one event: when, where, the call link,
/// who's invited and their RSVPs, and the description.
private struct EventDetail: View {
    @EnvironmentObject var state: AppState
    let event: EventItem
    @State private var notesHeight: CGFloat = 0
    private let field = RoundedRectangle(cornerRadius: 10, style: .continuous)

    private var when: String {
        "\(dayHeader(event.start)) · \(timeRange(event))"
    }

    /// The description without the call details Google appends (Meet link,
    /// dial-in, "Learn more…", "Please do not edit…"). With a Join button those
    /// are noise; whatever the organizer actually wrote stays.
    private var notes: String? {
        guard var n = event.notes, !n.isEmpty else { return nil }
        if let link = event.meeting {
            n = n.replacingOccurrences(of: #"-::~[:~]*::-"#, with: "", options: .regularExpression)
            n = n.components(separatedBy: .newlines)
                .filter { line in
                    let l = line.trimmingCharacters(in: .whitespaces).lowercased()
                    return !Self.callBoilerplate.contains { l.hasPrefix($0) }
                        && l != link.url.absoluteString.lowercased()
                }
                .joined(separator: "\n")
                .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        }
        n = n.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : n
    }

    private static let callBoilerplate = [
        "join with google meet", "join by phone", "or dial:", "pin:",
        "more phone numbers", "learn more about meet", "please do not edit this section",
        "meeting link:", "join zoom meeting", "join on your computer", "click here to join",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FilterHeader(title: "") {
                withAnimation(Motion.screen) { state.selectedEventID = nil }
            }
            .overlay(alignment: .trailing) {
                if !event.isCanceled {
                    Button { withAnimation(Motion.screen) { state.beginEditEvent(event) } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "pencil").font(.system(size: 11, weight: .semibold))
                            Text("Edit").font(.system(size: 13))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.system(size: 15, weight: .semibold))
                    .strikethrough(event.isCanceled, color: .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if event.isCanceled {
                    Text("Canceled").font(.system(size: 11, weight: .semibold)).foregroundStyle(.red)
                }
                detailLine("clock", when)
                HStack(spacing: 6) {
                    Circle().fill(state.eventColor(event) ?? event.calendarColor)
                        .frame(width: 8, height: 8)
                        .frame(width: 14)
                    Text(event.calendarName).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let loc = event.location, !loc.isEmpty,
                   event.meeting.map({ !loc.contains($0.url.host ?? "") }) ?? true {
                    detailLine("mappin", loc)
                }
            }

            if let link = event.meeting, !event.isCanceled {
                JoinButton(link: link, prominent: true, wide: true)
            }

            if !event.attendees.isEmpty { attendeeList }

            if let notes {
                ScrollView {
                    Text(notes)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8).padding(.horizontal, 10)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                            notesHeight = $0
                        }
                }
                .scrollEdges()
                .frame(height: min(notesHeight, 120))
                .background(field.fill(.white.opacity(0.05)))
            }
        }
        .padding(.top, 12).padding(.bottom, 4)
    }

    private func detailLine(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 14)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var attendeeList: some View {
        let going = event.attendees.filter { $0.rsvp == .accepted }.count
        return VStack(alignment: .leading, spacing: 4) {
            SectionLabelRow(title: "\(event.attendees.count) guests",
                            trailing: "\(going) going")
            VStack(alignment: .leading, spacing: 3) {
                ForEach(event.attendees.prefix(12)) { a in AttendeeRow(attendee: a) }
                if event.attendees.count > 12 {
                    Text("+\(event.attendees.count - 12) more")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .padding(.leading, 26)
                }
            }
            .padding(.vertical, 7).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(field.fill(.white.opacity(0.05)))
        }
    }
}

private struct SectionLabelRow: View {
    let title: String
    let trailing: String
    var body: some View {
        HStack {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            Spacer()
            Text(trailing).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

private struct AttendeeRow: View {
    let attendee: Attendee

    private var badge: (icon: String, color: Color, help: String) {
        switch attendee.rsvp {
        case .accepted:  return ("checkmark.circle.fill", .green, "Going")
        case .declined:  return ("xmark.circle.fill", .red, "Declined")
        case .tentative: return ("questionmark.circle.fill", .orange, "Maybe")
        case .pending:   return ("circle.dashed", .secondary, "No reply yet")
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: badge.icon).font(.system(size: 11)).foregroundStyle(badge.color)
                .help(badge.help)
            Text(attendee.isMe ? "\(attendee.name) (you)" : attendee.name)
                .font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(attendee.rsvp == .declined ? .secondary : .primary)
                .strikethrough(attendee.rsvp == .declined, color: .secondary)
            Spacer(minLength: 0)
            if attendee.isOrganizer {
                Text("Organizer").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.white.opacity(0.08)))
            }
        }
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

/// Menu items for picking one of several options, the chosen one checkmarked.
struct CheckmarkItems: View {
    let items: [(id: String, title: String)]
    let selected: String
    let select: (String) -> Void

    init(_ items: [(id: String, title: String)], selected: String,
         select: @escaping (String) -> Void) {
        self.items = items; self.selected = selected; self.select = select
    }

    var body: some View {
        ForEach(items, id: \.id) { item in
            Button { select(item.id) } label: {
                if item.id == selected {
                    Label(item.title, systemImage: "checkmark")
                } else {
                    Text(item.title)
                }
            }
        }
    }
}
