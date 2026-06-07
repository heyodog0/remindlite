import SwiftUI
import Combine
import EventKit

/// Central observable state. Owns the EventKit wrapper, the in-memory task list,
/// and refreshes when Reminders changes underneath us (EKEventStoreChanged).
@MainActor
final class AppState: ObservableObject {
    @Published var tasks: [TaskItem] = []
    @Published var events: [EventItem] = []
    @Published var tab: PanelTab = .reminders {
        didSet { applyCachedHeight() }
    }
    @Published var access: RemindersStore.Access = .unknown          // reminders
    @Published var calendarAccess: RemindersStore.Access = .unknown  // events
    @Published var panelVisible = false
    @Published var draft: String = ""            // the "add a reminder" field
    @Published var showCompleted = false         // Completed section collapsed by default

    /// Closes the panel. Set by StatusController; called from SwiftUI (tapping
    /// outside the glass) so the view layer can dismiss without knowing AppKit.
    var closePanel: (() -> Void)?

    // MARK: panel sizing
    //
    // The glass and all height animation live in SwiftUI now (the window is a
    // transparent canvas). `screenHeight` is the natural height of the current
    // screen — SwiftUI animates the body's frame to it, so the panel grows/shrinks
    // smoothly under the fixed header with no AppKit frame animation (nothing to
    // slide or blink). `panelContentHeight` is the full glass height the window
    // must at least cover; the window snaps to it invisibly (transparent margin).

    /// Natural height of the current screen's body (below the header). SwiftUI
    /// animates to this. Cached per screen so re-visiting one starts the animation
    /// in lockstep with the content cross-fade, not a frame late.
    @Published var screenHeight: CGFloat = 0 { didSet { recomputePanelHeight() } }

    /// Measured height of the fixed chrome (tabs + divider). Constant in practice.
    @Published var chromeHeight: CGFloat = 0 { didSet { recomputePanelHeight() } }

    /// Full glass height (chrome + body + padding); drives the transparent window.
    @Published var panelContentHeight: CGFloat = 0

    private let panelVPadding: CGFloat = 24   // .padding(12) top + bottom

    private func recomputePanelHeight() {
        let h = chromeHeight + screenHeight + panelVPadding
        if abs(h - panelContentHeight) > 0.5 { panelContentHeight = h }
    }

    /// Last measured body height per screen, so re-visiting one sizes immediately.
    private var cachedScreenHeights: [String: CGFloat] = [:]

    /// Identity of the screen currently shown — list, editor, or calendar.
    private var screenKey: String {
        if tab == .calendar { return "calendar" }
        if editingID == nil { return "list" }
        // The editor's height depends on whether the due-date/time sections are
        // shown, so cache each combination separately — that way toggling them
        // sizes the panel synchronously (like navigation) instead of a frame late.
        return "editor|\(editHasDue)|\(editHasTime)"
    }

    /// Heights of the toggle-able pieces of the editor, measured even while
    /// hidden, so the *first* toggle of Due Date or Time already knows the height
    /// delta and can animate (instead of snapping for lack of a cached height).
    var timeRowHeight: CGFloat = 0 { didSet { recacheEditorHeights() } }
    var dueContentHeight: CGFloat = 0 { didSet { recacheEditorHeights() } }
    private let dueBoxSpacing: CGFloat = 8   // the due-date box's VStack spacing

    /// Model the editor's height as base (Due Date off) + the due-content block
    /// (+spacing) when due is on + the time row (+spacing) when time is on. Given
    /// the current measured height and the two piece heights, derive and cache all
    /// four combinations — so every toggle is a known (animated) resize.
    private func recacheEditorHeights() {
        guard editingID != nil, tab == .reminders else { return }
        guard timeRowHeight > 0, dueContentHeight > 0,
              let current = cachedScreenHeights[screenKey] else { return }
        let dueDelta = dueContentHeight + dueBoxSpacing
        let timeDelta = timeRowHeight + dueBoxSpacing
        var base = current
        if editHasDue { base -= dueDelta }
        if editHasDue && editHasTime { base -= timeDelta }
        cachedScreenHeights["editor|false|false"] = base
        cachedScreenHeights["editor|false|true"]  = base
        cachedScreenHeights["editor|true|false"]  = base + dueDelta
        cachedScreenHeights["editor|true|true"]   = base + dueDelta + timeDelta
    }

    /// Called by the hidden probe with the current screen's natural body height.
    func reportScreenHeight(_ h: CGFloat) {
        guard h > 0 else { return }
        cachedScreenHeights[screenKey] = h
        recacheEditorHeights()
        guard abs(h - screenHeight) > 0.5 else { return }
        // Always apply a probe measurement instantly. It lands a frame *after* the
        // content changed, so animating it would teleport (content jumps in, then
        // the frame eases up to it). Smooth animation happens only when we already
        // know the destination height — see applyCachedHeight / the cache-aware
        // toggles. (When the measurement just confirms the cached value, the guard
        // above makes this a no-op, so it never cuts a running animation short.)
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { screenHeight = h }
    }

    /// Whether we already know (have measured) the editor's height for a given
    /// due/time combination. The toggles animate only when it's known, so the
    /// first time into a combination snaps cleanly instead of teleporting.
    func editorHeightCached(due: Bool, time: Bool) -> Bool {
        cachedScreenHeights["editor|\(due)|\(time)"] != nil
    }

    /// On a screen change, jump the body height to the cached value (if known) so
    /// the SwiftUI height animation starts together with the content transition.
    private func applyCachedHeight() {
        if let h = cachedScreenHeights[screenKey] { screenHeight = h }
    }

    /// Measured inner heights of the scrolling lists, kept here (not in @State on
    /// the list views) so they survive the views being torn down and rebuilt when
    /// you open/close the editor or switch tabs. Otherwise a rebuilt list starts
    /// at 0, collapses for a frame, and the panel jerks.
    @Published var listInnerHeight: CGFloat = 0
    @Published var eventInnerHeight: CGFloat = 0

    /// Task-editor state. `editingID != nil` shows the detail/edit view.
    @Published var editingID: String? {
        didSet { applyCachedHeight() }
    }
    @Published var editTitle = ""
    @Published var editNotes = ""
    @Published var editHasDue = false {
        didSet { applyCachedHeight() }
    }
    @Published var editDue = Date()
    @Published var editHasTime = true {
        didSet { applyCachedHeight() }
    }
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
        // Apply the edit to the in-memory list *before* leaving the editor, so the
        // row shows its new values the instant the list reappears. Mirrors exactly
        // what the store round-trip (update → fetch) produces, so the refresh()
        // below resolves to identical data — no flash of stale content, and no
        // second window resize. Without this, save snapped to the old row, then
        // snapped again when refresh() re-sorted it in.
        if let i = tasks.firstIndex(where: { $0.id == id }) {
            let old = tasks[i]
            tasks[i] = TaskItem(
                id: old.id,
                title: editTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                due: resolvedEditDue(),
                hasTime: editHasDue && editHasTime,
                priority: editPriority,
                notes: editNotes.isEmpty ? nil : editNotes,
                completed: old.completed,
                completionDate: old.completionDate)
        }
        editingID = nil
        store.update(id: id, title: editTitle, notes: editNotes,
                     due: editHasDue ? editDue : nil, hasTime: editHasTime,
                     priority: editPriority) { [weak self] in
            self?.refresh()
        }
    }

    /// The due date as the store will persist and re-read it: date-only when time
    /// is off, date+time otherwise (seconds dropped). Keeps the optimistic row in
    /// saveEdit identical to what the next fetch returns.
    private func resolvedEditDue() -> Date? {
        guard editHasDue else { return nil }
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: editDue)
        if editHasTime {
            let t = cal.dateComponents([.hour, .minute], from: editDue)
            comps.hour = t.hour; comps.minute = t.minute
        }
        return cal.date(from: comps)
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
