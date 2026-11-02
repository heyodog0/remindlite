// © 2026 Ryan Truong. All rights reserved. Not licensed for copying, porting or
// reimplementation, by hand or with AI tools. See LICENSE.

import Foundation

/// One line in the "Now" list: what you're doing this sitting. Either a quick
/// item (a throwaway line that lives only here) or a pin to a real reminder
/// (which stays in its own list; checking it off completes it in Reminders).
struct NowEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case quick, pinned }

    let id: String
    let kind: Kind
    var title: String          // quick items only
    /// Pinned only. `reminderUID` is the reminder's server id, identical on
    /// every Mac — pins match by it. `reminderID` is the local id, kept for pins
    /// made before UIDs were stored (resolved and upgraded on the Mac that made
    /// them).
    var reminderID: String?
    var reminderUID: String?
    var done: Bool             // quick items only (pins use the reminder's state)

    static func quick(_ title: String) -> NowEntry {
        NowEntry(id: UUID().uuidString, kind: .quick, title: title,
                 reminderID: nil, reminderUID: nil, done: false)
    }

    static func pin(_ item: TaskItem) -> NowEntry {
        NowEntry(id: "pin-\(item.externalID.isEmpty ? item.id : item.externalID)", kind: .pinned,
                 title: "", reminderID: item.id,
                 reminderUID: item.externalID.isEmpty ? nil : item.externalID, done: false)
    }

    func pins(_ item: TaskItem) -> Bool {
        guard kind == .pinned else { return false }
        if let uid = reminderUID, !item.externalID.isEmpty { return uid == item.externalID }
        return reminderID == item.id
    }
}

/// Reads and writes the Now list as a small JSON file. It lives in iCloud Drive
/// when available, so every Mac signed into the same account shares one list;
/// otherwise in Application Support (this Mac only). Nothing goes to Reminders.
/// Concurrent edits on two Macs resolve last-write-wins — fine for a short list.
final class NowFile {
    let url: URL
    private var watcher: DispatchSourceFileSystemObject?

    init() {
        let fm = FileManager.default
        let iCloud = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        let base = fm.fileExists(atPath: iCloud.path)
            ? iCloud.appendingPathComponent("RemindLite")
            : fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("RemindLite")
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("now.json")
    }

    func load() -> [NowEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([NowEntry].self, from: data)) ?? []
    }

    func save(_ entries: [NowEntry]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Calls `changed` (on main) when the folder changes — e.g. iCloud brought
    /// in an edit from the other Mac. Watches the folder, not the file, because
    /// atomic writes replace the file and would orphan a file watch.
    func watch(_ changed: @escaping () -> Void) {
        let fd = open(url.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler(handler: changed)
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }
}
