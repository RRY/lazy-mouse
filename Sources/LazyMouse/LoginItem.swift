import Foundation
import ServiceManagement

/// Launch at login through `SMAppService`.
///
/// The state is deliberately not stored a second time: the registration lives in the system
/// and can be changed there outside the app as well (System Settings → General → Login
/// Items). A private copy would drift away from it.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The user has explicitly denied launching at login in System Settings. `register()`
    /// then stays without effect until it is allowed there again.
    static var isBlockedBySystem: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Returns a description if the change did not go through.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "\(error.localizedDescription)"
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
