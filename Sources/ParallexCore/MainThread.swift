import Foundation

/// Run a main-actor-bound AppKit call from any thread.
///
/// The CLI invokes core operations on the main thread directly; the GUI runs
/// them in background tasks. AppKit entry points (NSWorkspace, …) hop to the
/// main thread here. Safe as long as the main thread is never blocked waiting
/// on the calling thread — and it isn't: the GUI awaits detached work while
/// its run loop keeps spinning.
func onMainThread(_ body: @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(body)
    } else {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated(body)
        }
    }
}

/// `onMainThread`, returning the body's value.
func onMainThreadValue<T: Sendable>(_ body: @MainActor @Sendable () -> T) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated(body)
    }
    return DispatchQueue.main.sync {
        MainActor.assumeIsolated(body)
    }
}
