import Foundation

#if canImport(Network)
    import Network
#endif
#if canImport(UIKit) && !os(watchOS)
    import UIKit
#endif

/// Reconnect at once, instead of waiting out the backoff, when a network
/// becomes available and when an iOS app returns to the foreground. Nothing on
/// Linux, where neither exists.
enum PlatformHooks {
    static func attach(reconnect: @escaping @Sendable () -> Void) -> [Registration] {
        var hooks: [Registration] = []
        #if canImport(Network)
            hooks.append(networkHook(reconnect))
        #endif
        #if canImport(UIKit) && !os(watchOS)
            hooks.append(foregroundHook(reconnect))
        #endif
        return hooks
    }

    #if canImport(Network)
        private static func networkHook(_ reconnect: @escaping @Sendable () -> Void) -> Registration {
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                if path.status == .satisfied { reconnect() }
            }
            monitor.start(queue: DispatchQueue(label: "dev.recached.network"))
            return Registration { monitor.cancel() }
        }
    #endif

    #if canImport(UIKit) && !os(watchOS)
        private static func foregroundHook(_ reconnect: @escaping @Sendable () -> Void) -> Registration {
            // By raw name: the UIApplication constant is main-actor isolated,
            // and this runs wherever the cache is opened.
            let name = Notification.Name("UIApplicationWillEnterForegroundNotification")
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                reconnect()
            }
            let observer = UncheckedSendable(token)
            return Registration { NotificationCenter.default.removeObserver(observer.value) }
        }
    #endif
}

/// For a value that is only ever handed back to the API that produced it.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
