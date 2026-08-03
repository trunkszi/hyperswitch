import AppKit

/// The running applications the ⌘Tab switcher walks, in most-recently-used order.
///
/// **This has to be maintained continuously; it cannot be computed on demand.** macOS
/// exposes no "applications in use order" anywhere: `NSWorkspace.runningApplications` is
/// in launch order, and `CGWindowListCopyWindowInfo` gives stacking order for windows
/// currently composited, which says nothing about an application whose windows are all on
/// another Space or minimised. The only observable that carries use order is the
/// activation notification, so the order is accumulated from it and kept for the life of
/// the process.
///
/// Only `.regular` applications are listed — the ones with a Dock tile. Accessory and
/// prohibited processes (menu bar agents, daemons, and this app) cannot be brought
/// forward in any meaningful sense, so offering them in a switcher would produce rows
/// that do nothing when chosen.
@MainActor
final class AppList {
    static let shared = AppList()

    /// What an entry in the order is.
    ///
    /// A pid alone is not an identity here. Pids are recycled, this list is kept for the
    /// life of the process, and an application that quits from position 1 would otherwise
    /// hand its slot to whatever process the kernel next gives that number to — the new
    /// arrival appearing as "the app you were just in", one ⌘Tab away, which is both wrong
    /// and destructive to the single-flick-back behaviour the whole row is built around.
    /// Pairing the pid with the bundle identifier makes a recycled pid fail to match, so
    /// the newcomer joins at the back where it belongs.
    ///
    /// `nonisolated` because it is built inside the workspace notification blocks, which
    /// are not main-actor contexts, and because a main-actor-isolated `Hashable` cannot be
    /// put in a `Set`.
    private nonisolated struct AppKey: Hashable {
        let pid: pid_t
        /// `nil` for processes LaunchServices does not know as applications; matched as a
        /// value like any other, so two such processes still differ by pid.
        let bundleIdentifier: String?
    }

    /// Applications, most recently activated first.
    private var order: [AppKey] = []
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private init() {}

    func start() {
        guard activationObserver == nil else { return }

        // Launch order is not use order, but it is the only ordering that exists before
        // the first activation notification arrives. One activation corrects it, and the
        // frontmost application is placed correctly right away — which is the only
        // position that has to be right for the very first ⌘Tab.
        let workspace = NSWorkspace.shared
        order = workspace.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
            .map(Self.key)
        if let front = workspace.frontmostApplication {
            promote(Self.key(front))
        }

        activationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let application = notification
                .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }

            // Flattened to a plain value before the hop, like everything else that crosses
            // an isolation boundary here — `NSRunningApplication` itself must not.
            let key = Self.key(application)

            // The block runs on the main thread because the queue is the main queue, so
            // this really is the main actor. Recording the change here rather than from a
            // fresh `Task` is what makes "activate an application, immediately press
            // ⌘Tab" show the new order instead of the one from a moment ago.
            MainActor.assumeIsolated { self?.promote(key) }
        }

        // Termination is watched even though `switcherApps()` already drops applications
        // that have gone: that pass only runs when the switcher is opened, and the pid of
        // an application that quit in the meantime can be handed to a new process before
        // then. Forgetting it at the moment it dies means the recycled pid can never be
        // seen as the old application at all, whatever it turns out to be.
        terminationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let application = notification
                .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            let pid = application.processIdentifier
            MainActor.assumeIsolated { self?.order.removeAll { $0.pid == pid } }

            // The same moment is the only reliable one for dropping the Accessibility
            // elements held for that process. `AXCore` caches one `AXUIElement` per pid,
            // and an application element is a **mach port send right** into that process —
            // holding one for a process that has exited keeps a kernel resource alive for
            // nothing. Its only other caller is "the user quit this application from the
            // switcher", so for an agent that stays running for weeks across hundreds of
            // launches the table only ever grew. `AXCore.forget` is `nonisolated` and
            // fire-and-forget precisely so it can be called from here.
            AXCore.shared.forget(pid: pid)
        }

        Log.windows.debug("app list seeded with \(self.order.count) applications")
    }

    /// The switcher's application row.
    ///
    /// Index 0 is the frontmost application, matching the system's own ⌘Tab: the first
    /// Tab press moves to index 1, the application you were in before, so a single flick
    /// swaps between two applications.
    func switcherApps() -> [AppEntry] {
        let workspace = NSWorkspace.shared
        let running = workspace.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID }
        var byPID: [pid_t: NSRunningApplication] = [:]
        for application in running { byPID[application.processIdentifier] = application }

        // Re-assert the frontmost application rather than trusting the notification
        // stream alone. Anything that came forward before `start()` ran produced no
        // notification we saw, and the invariant "index 0 is where you are now" is one
        // the whole switcher is built on — cheap to guarantee, confusing to get wrong.
        if let front = workspace.frontmostApplication, byPID[front.processIdentifier] != nil {
            promote(Self.key(front))
        }

        // Applications that have quit drop out here, and so does any entry whose pid now
        // belongs to something else — a bundle identifier that no longer matches means the
        // number was recycled, and the remembered position was earned by a process that is
        // gone. Ones that launched without ever coming forward join at the back, the
        // correct place for "least recently used".
        order.removeAll { entry in
            guard let application = byPID[entry.pid] else { return true }
            return application.bundleIdentifier != entry.bundleIdentifier
        }
        let known = Set(order)
        for application in running where !known.contains(Self.key(application)) {
            order.append(Self.key(application))
        }

        return order.compactMap { entry in
            guard let application = byPID[entry.pid] else { return nil }
            return AppEntry(
                pid: entry.pid,
                name: application.localizedName ?? "",
                bundleIdentifier: application.bundleIdentifier,
                // Left at zero deliberately: counting windows means a
                // `CGWindowListCopyWindowInfo` pass, and this runs on the main actor at
                // hotkey time. `SwitcherController` fills the counts in from
                // `WindowIndex.windowCounts(_:)`, which it already has to call.
                windowCount: 0
            )
        }
    }

    private func promote(_ key: AppKey) {
        guard key.pid != ownPID else { return }
        // Removed by pid, not by whole key: if the pid was recycled, the entry under it is
        // stale and has to go regardless of which bundle it names.
        order.removeAll { $0.pid == key.pid }
        order.insert(key, at: 0)
    }

    /// `nonisolated` so the notification blocks can build a key without hopping first.
    private nonisolated static func key(_ application: NSRunningApplication) -> AppKey {
        AppKey(pid: application.processIdentifier,
               bundleIdentifier: application.bundleIdentifier)
    }
}
