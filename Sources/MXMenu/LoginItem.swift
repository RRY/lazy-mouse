import Foundation
import ServiceManagement

/// Autostart beim Login über `SMAppService`.
///
/// Der Zustand wird bewusst nicht zusätzlich gespeichert: die Registrierung lebt im System
/// und kann dort auch außerhalb der App geändert werden (Systemeinstellungen → Allgemein →
/// Anmeldeobjekte). Eine eigene Kopie würde davon abweichen.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Der Nutzer hat den Autostart in den Systemeinstellungen ausdrücklich abgelehnt.
    /// Ein `register()` bleibt dann wirkungslos, bis er dort wieder freigegeben wird.
    static var isBlockedBySystem: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Gibt eine Fehlerbeschreibung zurück, wenn die Änderung nicht durchging.
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
