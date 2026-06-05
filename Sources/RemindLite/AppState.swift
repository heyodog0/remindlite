import SwiftUI
import Combine
import EventKit

/// Central observable state. Owns the EventKit wrapper, the in-memory task list,
/// and refreshes when Reminders changes underneath us (EKEventStoreChanged).
@MainActor
final class AppState: ObservableObject {
    @Published var tasks: [TaskItem] = []
    @Published var events: [EventItem] = []
    @Published var tab: PanelTab = .reminders
    @Published var access: RemindersStore.Access = .unknown          // reminders
    @Published var calendarAccess: RemindersStore.Access = .unknown  // events
    @Published var panelVisible = false
    @Published var draft: String = ""            // the "add a reminder" field
    @Published var showCompleted = false         // Completed section collapsed by default

    /// Natural (ideal) height of the panel content; the window is sized to it.
    @Published var panelContentHeight: CGFloat = 0

    /// Task-editor state. `editingID != nil` shows the detail/edit view.
    @Published var editingID: String?
    @Published var editTitle = ""
    @Published var editNotes = ""
    @Published var editHasDue = false
    @Published var editDue = Date()
    @Published var editHasTime = true
    @Published var editPriority = 0       // 0 none, 1 high, 5 medium, 9 low

    /// How many days of events to show in the Calendar tab.
    let eventWindowDays = 7

    /// Optimistic completion overrides: id → desired completed state, applied
    /// instantly on tap and cleared once a refetch confirms it. Lets a check (or
    /// un-check) feel immediate without an empty flash.
    @Published var optimistic: [String: Bool] = [:]

    private let store = RemindersStore()
    private var pollTimer: Timer?

    init() {
        access = store.access
        calendarAccess = store.calendarAccess
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeChanged),
            name: .EKEventStoreChanged, object: store.store)

        // Recompute periodically so overdue/today reclassify across midnight even
        // if nothing in Reminders changed.
        let t = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 10
        pollTimer = t

        if access == .granted { refresh() }
        if calendarAccess == .granted { refreshEvents() }
    }

    @objc private func storeChanged() {
        Task { @MainActor in
            self.refresh()
            self.refreshEvents()
        }
    }

    /// Ask for access (first launch / after a denial the user reversed).
    func requestAccess() {
        store.requestAccess { [weak self] granted in
            guard let self else { return }
            self.access = granted ? .granted : .denied
            if granted { self.refresh() }
        }
    }

    /// Ask for calendar access (first time the user opens the Calendar tab).
    func requestCalendarAccess() {
        store.requestCalendarAccess { [weak self] granted in
            guard let self else { return }
            self.calendarAccess = granted ? .granted : .denied
            if granted { self.refreshEvents() }
        }
    }

    func refreshEvents() {
        calendarAccess = store.calendarAccess
        guard calendarAccess == .granted else { return }
        store.fetchEvents(days: eventWindowDays) { [weak self] items in
            self?.events = items
        }
    }

    func refresh() {
        access = store.access
        guard access == .granted else { return }
        store.fetchAll { [weak self] items in
            guard let self else { return }
            self.tasks = items
            // Drop optimistic overrides once the fetch agrees with them.
            self.optimistic = self.optimistic.filter { id, want in
                guard let it = items.first(where: { $0.id == id }) else { return false }
                return it.completed != want
            }
        }
    }

    /// Effective completed state: the optimistic override if any, else the store.
    func isCompleted(_ item: TaskItem) -> Bool { optimistic[item.id] ?? item.completed }

    /// Flip a task's completion (works in both directions), optimistically.
    func toggle(_ item: TaskItem) {
        let target = !isCompleted(item)
        optimistic[item.id] = target
        store.setCompleted(item.id, target) { [weak self] in self?.refresh() }
    }

    func add() {
        let text = draft
        draft = ""
        store.add(title: text) { [weak self] in self?.refresh() }
    }

    /// Delete a reminder, optimistically removing it from the list first.
    func delete(_ item: TaskItem) {
        tasks.removeAll { $0.id == item.id }
        optimistic[item.id] = nil
        store.delete(item.id) { [weak self] in self?.refresh() }
    }

    // MARK: - task editor (notes / dates / priority)

    /// Open the editor for a task, populating the draft fields from it.
    func beginEdit(_ item: TaskItem) {
        editTitle = item.title
        editNotes = item.notes ?? ""
        editHasDue = item.due != nil
        editDue = item.due ?? defaultDueDate()
        editHasTime = item.hasTime
        editPriority = item.priority
        editingID = item.id
    }

    func cancelEdit() { editingID = nil }

    func saveEdit() {
        guard let id = editingID else { return }
        editingID = nil
        store.update(id: id, title: editTitle, notes: editNotes,
                     due: editHasDue ? editDue : nil, hasTime: editHasTime,
                     priority: editPriority) { [weak self] in
            self?.refresh()
        }
    }

    /// Delete the task currently being edited.
    func deleteEditing() {
        guard let id = editingID, let item = tasks.first(where: { $0.id == id }) else {
            editingID = nil; return
        }
        editingID = nil
        delete(item)
    }

    private func defaultDueDate() -> Date {
        // Today at 9:00 AM (a sensible default when turning a due date on).
        let cal = Calendar.current
        return cal.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
    }

    func openRemindersApp() {
        if let url = URL(string: "x-apple-reminderkit://") {
            NSWorkspace.shared.open(url)
        }
    }

    func openCalendarApp() {
        if let url = URL(string: "ical://") {
            NSWorkspace.shared.open(url)
        }
    }

    func openPrivacySettings(_ tab: PanelTab) {
        let pane = tab == .reminders ? "Privacy_Reminders" : "Privacy_Calendars"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - derived

    /// Open tasks grouped into due-date sections; empty buckets omitted.
    var sections: [(bucket: Bucket, items: [TaskItem])] {
        Bucket.allCases.compactMap { b in
            let items = tasks.filter { !isCompleted($0) && bucket(for: $0.due) == b }
            return items.isEmpty ? nil : (b, items)
        }
    }

    /// Tasks shown in the "Completed" section (completed today, newest first).
    var completedItems: [TaskItem] {
        tasks.filter { isCompleted($0) }
    }

    /// Events grouped by day (already chronologically sorted) for the Calendar tab.
    var eventDays: [(day: Date, header: String, items: [EventItem])] {
        let cal = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [EventItem]] = [:]
        for e in events {
            let key = cal.startOfDay(for: e.start)
            if byDay[key] == nil { order.append(key) }
            byDay[key, default: []].append(e)
        }
        return order.map { ($0, dayHeader($0), byDay[$0] ?? []) }
    }

    /// Menu-bar badge: open overdue + due-today (completed items don't count).
    var badgeCount: Int {
        tasks.filter {
            !isCompleted($0) && Bucket.badgeBuckets.contains(bucket(for: $0.due))
        }.count
    }

    /// Any open overdue items? Tints the badge red.
    var hasOverdue: Bool {
        tasks.contains { !isCompleted($0) && bucket(for: $0.due) == .overdue }
    }
}
