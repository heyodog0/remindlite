import SwiftUI

struct MenuContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            TabBar()
            Divider().opacity(0.35)

            if state.tab == .reminders {
                if state.editingID != nil {
                    TaskDetail()
                } else {
                    accessGate(state.access, denied: "Reminders access is off",
                               prompt: "Show your reminders here") { TaskList() }
                }
            } else {
                accessGate(state.calendarAccess, denied: "Calendar access is off",
                           prompt: "Show your events here") { EventList() }
            }
        }
        .padding(12)
        .fixedSize(horizontal: false, vertical: true)   // hug content vertically
        // Measure the ideal content height (before RootView's fill frame) so the
        // window can size to it. fixedSize above keeps this the natural height,
        // not the window height — no feedback loop.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
            state.panelContentHeight = h
        }
        // First time the Calendar tab is opened, ask for permission.
        .onChange(of: state.tab) { _, newTab in
            if newTab == .calendar && state.calendarAccess == .unknown {
                state.requestCalendarAccess()
            }
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

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                ForEach(PanelTab.allCases) { t in
                    TabSegment(tab: t, selected: state.tab == t, namespace: pill) {
                        // Don't wrap state.tab in withAnimation — that would animate
                        // the content-height change and make the window slide. Only
                        // the pill animates (via .animation(value:) below).
                        state.tab = t
                    }
                }
            }
            .padding(2)
            .background(shape.fill(.white.opacity(0.06)))
            .overlay(shape.strokeBorder(.white.opacity(0.10), lineWidth: 0.8))
            .animation(.easeInOut(duration: 0.22), value: state.tab)

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
            Label(tab.title, systemImage: tab.icon)
                .font(.system(size: 12, weight: .medium))
                .padding(.vertical, 5).padding(.horizontal, 9)
                .frame(maxWidth: .infinity)
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
    }
}

private struct TaskList: View {
    @EnvironmentObject var state: AppState
    @State private var innerHeight: CGFloat = 0
    private let scrollCap: CGFloat = 420   // scroll past this; below it the panel hugs content

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if state.sections.isEmpty && state.completedItems.isEmpty {
                        EmptyState()
                    }
                    ForEach(state.sections, id: \.bucket.id) { section in
                        Section(title: section.bucket.title, accent: section.bucket.accent,
                                items: section.items)
                    }
                    if !state.completedItems.isEmpty {
                        CompletedSection(items: state.completedItems)
                    }
                }
                .padding(.vertical, 10)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { innerHeight = $0 }
            }
            .frame(height: min(innerHeight, scrollCap))

            Divider().opacity(0.35)
            if state.creatingList {
                NewListForm().padding(.top, 8)
            } else {
                AddField().padding(.top, 8)
            }
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
    @State private var barHover = false
    @State private var rowHeight: CGFloat = 44   // measured; gives the color menu a real height

    private let barWidth: CGFloat = 18    // visible colored block
    private let clickWidth: CGFloat = 30  // click target = bar + a little of the gap

    private var done: Bool { state.isCompleted(item) }

    var body: some View {
        HStack(spacing: 0) {
            // Left color block = the list/color group. It's wide so it's an easy
            // click target; the actual click is handled by the overlay below so
            // the color always renders at full height.
            Rectangle()
                .fill(item.listColor)
                .frame(width: barWidth)
                .frame(maxHeight: .infinity)
                .brightness(barHover ? 0.12 : 0)

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
                            if item.priority == 1 {
                                Text("!!!").font(.system(size: 11, weight: .bold)).foregroundStyle(.red)
                            }
                            Text(item.title)
                                .font(.system(size: 13))
                                .strikethrough(done, color: .secondary)
                                .foregroundStyle(done ? .secondary : .primary)
                                .lineLimit(2)
                        }
                        if let label = dueLabel(item.due, hasTime: item.hasTime) {
                            Text(label)
                                .font(.system(size: 11))
                                .foregroundStyle(bucket(for: item.due) == .overdue ? .red : .secondary)
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
            .padding(.vertical, 5).padding(.leading, 14).padding(.trailing, 9)
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { rowHeight = $0 }
        // Click the wide left color zone to change the task's list (and thus
        // color). The menu label is given a DEFINITE height (the measured row
        // height) — a borderless menu button with an indefinite height collapses
        // to zero and becomes unclickable.
        .overlay(alignment: .leading) {
            Menu {
                ForEach(state.lists) { l in
                    Button { state.move(item, toList: l) } label: {
                        if l.name == item.listName {
                            Label(l.name, systemImage: "checkmark")
                        } else {
                            Text(l.name)
                        }
                    }
                }
                Divider()
                Button { state.beginNewList(move: item) } label: {
                    Label("New List…", systemImage: "plus")
                }
            } label: {
                Rectangle()
                    .fill(.white.opacity(0.001))
                    .frame(width: clickWidth, height: rowHeight)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .onHover { barHover = $0 }
            .help("Change list / color: \(item.listName)")
        }
        .opacity(done ? 0.55 : 1)
        .onHover { hovering = $0 }
        .contextMenu {
            Menu("Move to List") {
                ForEach(state.lists) { l in
                    Button { state.move(item, toList: l) } label: {
                        if l.name == item.listName {
                            Label(l.name, systemImage: "checkmark")
                        } else {
                            Text(l.name)
                        }
                    }
                }
                Divider()
                Button { state.beginNewList(move: item) } label: {
                    Label("New List…", systemImage: "plus")
                }
            }
            Divider()
            Button(role: .destructive) { state.delete(item) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct AddField: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Pick which list the new reminder lands in (swatch = current list).
            Menu {
                ForEach(state.lists) { l in
                    Button { state.addListID = l.id } label: {
                        if l.id == state.addListID {
                            Label(l.name, systemImage: "checkmark")
                        } else {
                            Text(l.name)
                        }
                    }
                }
                Divider()
                Button { state.beginNewList() } label: {
                    Label("New List…", systemImage: "plus")
                }
            } label: {
                Circle()
                    .fill(state.addList?.color ?? .secondary)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.8))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add to: \(state.addList?.name ?? "default list")")

            TextField("Add a reminder…", text: $state.draft)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit {
                    state.add()
                    focused = true            // keep focus to add another
                }
        }
        .padding(.vertical, 7).padding(.horizontal, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(focused ? .blue.opacity(0.5) : .white.opacity(0.12), lineWidth: 0.8))
        // Tapping anywhere in the pill focuses the field (bigger hit target).
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

/// Inline "new list" form (name + color), shown in place of the add field — no
/// popup window. Mirrors how the Reminders app pairs a list with one color.
private struct NewListForm: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool

    private var canCreate: Bool {
        !state.newListName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEW LIST")
                .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Circle()
                    .fill(reminderPalette.first { $0.id == state.newListColorID }?.color ?? .blue)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.8))
                TextField("List name", text: $state.newListName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onSubmit { if canCreate { state.confirmNewList() } }
            }
            .padding(.vertical, 7).padding(.horizontal, 9)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.blue.opacity(0.45), lineWidth: 0.8))

            // Color palette — pick the list's color (Reminders-style).
            HStack(spacing: 7) {
                ForEach(reminderPalette) { opt in
                    Circle()
                        .fill(opt.color)
                        .frame(width: 19, height: 19)
                        .overlay(Circle().strokeBorder(.white,
                            lineWidth: state.newListColorID == opt.id ? 2 : 0))
                        .contentShape(Circle())
                        .onTapGesture { state.newListColorID = opt.id }
                }
            }

            HStack {
                Button("Cancel") { state.cancelNewList() }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .font(.system(size: 12))
                Spacer()
                Button("Create") { state.confirmNewList() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canCreate)
            }
        }
        .onAppear { focused = true }
    }
}

/// Task editor — title, notes, due date, priority, and list. Shown in place of
/// the reminders list when a task is tapped.
private struct TaskDetail: View {
    @EnvironmentObject var state: AppState
    private let field = RoundedRectangle(cornerRadius: 10, style: .continuous)

    private var canSave: Bool {
        !state.editTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
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
                        .padding(.vertical, 4).padding(.horizontal, 15)
                        .background(Capsule().fill(Color.blue.opacity(canSave ? 0.8 : 0.3)))
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

            // Due date — one compact row + an inline picker when enabled.
            VStack(spacing: 8) {
                HStack {
                    Label("Due Date", systemImage: "calendar")
                        .font(.system(size: 13))
                    Spacer()
                    Toggle("", isOn: $state.editHasDue.animation(.easeInOut(duration: 0.15)))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                }
                if state.editHasDue {
                    HStack(spacing: 8) {
                        DatePicker("", selection: $state.editDue,
                                   displayedComponents: state.editHasTime ? [.date, .hourAndMinute] : [.date])
                            .datePickerStyle(.field).labelsHidden()
                        Spacer()
                        Toggle("Time", isOn: $state.editHasTime)
                            .toggleStyle(.switch).controlSize(.mini)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 9).padding(.horizontal, 10)
            .background(field.fill(.white.opacity(0.05)))
            .overlay(field.strokeBorder(.white.opacity(0.08), lineWidth: 0.8))

            // Priority
            Picker("", selection: $state.editPriority) {
                Text("None").tag(0)
                Text("Low").tag(9)
                Text("Medium").tag(5)
                Text("High").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()

            // List + delete on one compact row each
            HStack {
                Text("List").font(.system(size: 13))
                Spacer()
                Menu {
                    ForEach(state.lists) { l in
                        Button { state.editListID = l.id } label: {
                            if l.id == state.editListID {
                                Label(l.name, systemImage: "checkmark")
                            } else { Text(l.name) }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(state.editList?.color ?? .secondary).frame(width: 11, height: 11)
                        Text(state.editList?.name ?? "List").font(.system(size: 13))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(field.fill(.white.opacity(0.05)))
            .overlay(field.strokeBorder(.white.opacity(0.08), lineWidth: 0.8))

            Button { state.deleteEditing() } label: {
                Label("Delete", systemImage: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.plain).foregroundStyle(.red)
            .background(field.fill(.red.opacity(0.10)))
        }
        .padding(.top, 2)
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

/// Calendar (events) list, grouped by day across the next week.
private struct EventList: View {
    @EnvironmentObject var state: AppState
    @State private var innerHeight: CGFloat = 0
    private let scrollCap: CGFloat = 440

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if state.eventDays.isEmpty {
                    NoEvents()
                }
                ForEach(state.eventDays, id: \.day) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.header.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                        ForEach(group.items) { EventRow(event: $0) }
                    }
                }
            }
            .padding(.vertical, 10)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { innerHeight = $0 }
        }
        .frame(height: min(innerHeight, scrollCap))
    }
}

private struct EventRow: View {
    let event: EventItem
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(event.calendarColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13)).lineLimit(2)
                Text(timeRange(event))
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
