import Observation
import ServiceManagement

/// „Bei Login starten“ über `SMAppService.mainApp`.
@MainActor
@Observable
final class LoginItem {
    private(set) var isEnabled = false
    private(set) var needsApproval = false
    private(set) var lastError: String?

    init() {
        reload()
    }

    func reload() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        reload()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
