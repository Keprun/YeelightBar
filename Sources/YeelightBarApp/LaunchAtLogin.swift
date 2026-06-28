import Foundation
import ServiceManagement

/// Launch-at-login via the modern ServiceManagement API (macOS 13+). Registers the main app bundle
/// itself as a login item — no separate helper target needed.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            let svc = SMAppService.mainApp
            do {
                if newValue {
                    if svc.status != .enabled { try svc.register() }
                } else if svc.status == .enabled {
                    try svc.unregister()
                }
            } catch {
                NSLog("LaunchAtLogin: \(newValue ? "register" : "unregister") failed — \(error.localizedDescription)")
            }
        }
    }
}
