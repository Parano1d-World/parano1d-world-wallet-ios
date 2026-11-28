import Foundation
#if canImport(BackgroundTasks) && !targetEnvironment(macCatalyst)
import BackgroundTasks

/// Keeps the on-device node, and with it NFT and token State, close to the chain while the
/// app is closed, so Send is ready when the person opens it. iOS decides when (and whether)
/// this runs, usually while the phone is idle on Wi-Fi or charging. It downloads and checks
/// public chain data only: no keys are used, nothing is signed or sent.
@MainActor enum BackgroundNodeSync {
    static let identifier = "com.koajent.parano1d.wallet.node-sync"
    private static weak var node: DeviceNode?
    private static var registered = false

    /// Must run before the app finishes launching.
    static func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            MainActor.assumeIsolated { run(task) }
        }
    }
    static func attach(_ node: DeviceNode) { self.node = node }

    /// Called when the app goes to the background.
    static func schedule() {
        guard registered, node?.enabled == true else { return }
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Completes the system task exactly once, whichever of finishing or expiry happens first.
    private final class Completion {
        let task: BGProcessingTask
        private var done = false
        init(_ task: BGProcessingTask) { self.task = task }
        @MainActor func finish(_ success: Bool) { guard !done else { return }; done = true; task.setTaskCompleted(success: success) }
    }

    private static func run(_ task: BGProcessingTask) {
        schedule() // keep the chain of background refreshes going
        guard let node, node.enabled, !UserDefaults.standard.bool(forKey: "offlineMode") else { task.setTaskCompleted(success: true); return }
        let completion = Completion(task)
        let work = Task { @MainActor in
            node.synchronize(unlocked: true, offline: false, force: true, owner: nil)
            // Wait for this pass to finish (the node publishes a new verified boundary and State).
            for _ in 0..<(25 * 60) where node.running {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            completion.finish(node.error == nil)
        }
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in node.pause(); completion.finish(false) }
        }
    }
}
#else
@MainActor enum BackgroundNodeSync {
    static func register() {}
    static func attach(_ node: DeviceNode) {}
    static func schedule() {}
}
#endif
