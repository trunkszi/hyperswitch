import Foundation
import ServiceManagement

/// Registers HyperSwitch to start at login.
///
/// `SMAppService.mainApp` works for a locally signed build — verified moving through
/// `notFound → enabled → notRegistered` with no prompt and no Developer ID.
///
/// There is deliberately no stored mirror of the answer: `status` is read straight from
/// the service every time. A cached copy drifts, because registration can fail and
/// because the user can delete the item under System Settings ▸ General ▸ Login Items
/// without the app hearing about it — which is exactly how a switch ends up showing
/// "on" for something that will never happen.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registration throws when the app is somewhere `launchd` will not accept — the usual
    /// case being a build run from `~/Desktop` or a DerivedData path rather than
    /// `/Applications`.
    ///
    /// The failure is *returned*, not only logged. Because `isEnabled` reads the real
    /// service, a failed registration makes the switch spring back on the next redraw with
    /// no explanation at all — the user flips it, it flips itself back, and the only trace
    /// is a line in the unified log they will never see. The caller surfaces the reason.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<Void, any Error> {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(())
        } catch {
            let verb = enabled ? "register" : "unregister"
            Log.app.error("could not \(verb, privacy: .public) login item: \(error.localizedDescription, privacy: .public)")
            return .failure(error)
        }
    }
}
