import Foundation
import ServiceManagement

/// Launch-at-login via the modern ServiceManagement API (registers the app
/// bundle as a login item; no helper or LaunchAgent plist needed).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Register the *current* bundle, clearing any stale registration that
    /// points at a previous location (e.g. after moving the app).
    static func forceEnable() {
        try? SMAppService.mainApp.unregister()
        do { try SMAppService.mainApp.register() }
        catch { NSLog("RemindLite: login item register failed: \(error.localizedDescription)") }
    }

    @discardableResult
    static func setEnabled(_ on: Bool) -> Bool {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            return true
        } catch {
            NSLog("RemindLite: login item \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
            return false
        }
    }
}
