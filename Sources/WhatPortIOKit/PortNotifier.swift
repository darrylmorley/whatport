import Foundation
import IOKit
import os

// Watches for IOKit state-change notifications on USB-C port services and
// signals "something changed" so the caller can re-read all state.
//
// Two complementary mechanisms, because a plug/unplug shows up in IOKit in
// more than one way:
//
// 1. Matching notifications (IOServiceAddMatchingNotification): fire when a
//    service APPEARS or is TERMINATED. A plug often brings up new transport
//    services (USB3 / DisplayPort / CIO) and a device; an unplug tears them
//    down. We treat any appear/terminate on a watched class as a change.
//
// 2. Interest notifications (IOServiceAddInterestNotification, kIOGeneral
//    interest): fire when an existing service's PROPERTIES change. The CC
//    service is persistent per port, so a cable plugged into an otherwise
//    empty port toggles its "Active" property without any service appearing.
//    We register interest on every watched service to catch that.
//
// Earlier this only watched IOPortTransportStateCC and only registered
// interest, so a plug that appeared as a new service (rather than a CC
// property change) was missed until the 3s poll, which read as intermittent
// "catch-up" lag. Watching the transport classes and signalling on
// appearance/termination closes that gap.
//
// All notifications are coalesced with a short debounce (a plug fires ~100
// notifications in a burst); the caller re-reads all state once things settle.
//
// IOAccessoryManager is also watched, for a different reason: its interest
// notifications carry decoded lifecycle messages (attach / negotiating /
// contract established / transport ready) that the transport classes never
// emit. Those are surfaced synchronously via onLifecycleEvent, alongside the
// same debounced refresh the other classes trigger.

final class PortNotifier: @unchecked Sendable {
    // Classes whose appearance / termination / property changes indicate a
    // port state change. CC covers cable-only plugs into empty ports; the
    // transport classes cover links coming up when a device is connected.
    // IOAccessoryManager is the source of decoded lifecycle events.
    private static let watchedClasses = [
        "IOPortTransportStateCC",
        "IOPortTransportStateUSB3",
        "IOPortTransportStateDisplayPort",
        "IOPortTransportStateCIO",
        "IOAccessoryManager",
    ]

    // Per-watched-class refcon. The old code shared one refcon (self) across
    // every registration, so a callback firing on IOAccessoryManager could
    // not be told apart from one firing on IOPortTransportStateCC. One
    // context per watched class carries that identity through instead.
    private final class WatchContext {
        unowned let notifier: PortNotifier
        let className: String

        init(notifier: PortNotifier, className: String) {
            self.notifier = notifier
            self.className = className
        }
    }

    // The identity (physical port number + MagSafe flag) of an IOAccessoryManager
    // service, resolved once when interest is registered and cached by registry
    // entry ID. Only IOAccessoryManager services that identify as a built-in
    // port get an entry; anything else is simply absent from the dictionary,
    // which handleInterest treats as "no lifecycle decoding for this service".
    private struct PortIdentity {
        let portNumber: Int
        let isMagSafe: Bool
    }

    private var notifyPort: IONotificationPortRef?
    private var matchedIterators: [io_iterator_t] = []
    private var interestNotifications: [UInt64: io_object_t] = [:]
    // One retained WatchContext pointer per watched class, released in stop().
    // Reused as the refcon for every service's interest registration under
    // that class, so no additional retain is taken per service.
    private var watchContextPointers: [UnsafeMutableRawPointer] = []
    private var portIdentities: [UInt64: PortIdentity] = [:]
    private var onChange: (@Sendable () -> Void)?
    private var onLifecycleEvent: (@Sendable (RawPortLifecycleEvent) -> Void)?
    private let queue = DispatchQueue(label: "app.whatport.notifier")
    private var debounceTask: Task<Void, Never>?
    // Suppresses the change signal during the initial arming drain, so we
    // don't fire a redundant re-read right after start() (the caller already
    // takes an initial snapshot).
    private var isArming = false
    // Guards stop() so two concurrent calls can't both pass the "not yet
    // stopped" check and both proceed to destroy the port / release the
    // WatchContext pointers. Reset by start() so a stop()-then-start() cycle
    // (restart) works.
    private let stopLock = OSAllocatedUnfairLock(initialState: false)

    // Must not be called from `queue` (the notifier's own dispatch queue):
    // the registration loop below runs inside a queue.sync, which would
    // deadlock if start() were re-entered from that queue. Like stop(), the
    // only caller is the app main thread.
    func start(
        onChange: @escaping @Sendable () -> Void,
        onLifecycleEvent: @escaping @Sendable (RawPortLifecycleEvent) -> Void
    ) {
        // Pairs with stop() latching this true: without resetting it here, a
        // stop()-then-start() restart would leave the next stop() thinking
        // it already ran and returning immediately without tearing down.
        stopLock.withLock { $0 = false }

        self.onChange = onChange
        self.onLifecycleEvent = onLifecycleEvent

        let port = IONotificationPortCreate(kIOMainPortDefault)
        IONotificationPortSetDispatchQueue(port, queue)
        notifyPort = port

        let matchCallback: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let context = Unmanaged<WatchContext>.fromOpaque(refcon).takeUnretainedValue()
            context.notifier.handleMatched(iter, context: context, contextPtr: refcon)
        }

        let terminateCallback: IOServiceMatchingCallback = { refcon, iter in
            guard let refcon else { return }
            let context = Unmanaged<WatchContext>.fromOpaque(refcon).takeUnretainedValue()
            context.notifier.handleTerminated(iter)
        }

        // The arming drain below (handleMatched/handleTerminated) mutates
        // matchedIterators, interestNotifications and portIdentities on this
        // thread; a callback for a class armed earlier in this same loop can
        // fire concurrently on `queue` and mutate the same dictionaries.
        // Running the whole registration loop inside queue.sync serialises
        // the two, mirroring the drain barrier stop() uses for teardown.
        // This cannot deadlock: IOServiceAddMatchingNotification does not
        // call back into `queue` synchronously, so nothing here re-enters
        // queue.sync from queue itself.
        queue.sync {
            isArming = true
            for className in Self.watchedClasses {
                let context = WatchContext(notifier: self, className: className)
                let contextPtr = Unmanaged.passRetained(context).toOpaque()
                watchContextPointers.append(contextPtr)

                // Watch services appearing.
                var appearIter: io_iterator_t = 0
                if IOServiceAddMatchingNotification(
                    port, kIOMatchedNotification, IOServiceMatching(className),
                    matchCallback, contextPtr, &appearIter
                ) == KERN_SUCCESS {
                    matchedIterators.append(appearIter)
                    handleMatched(appearIter, context: context, contextPtr: contextPtr)  // drain to arm + register interest
                }

                // Watch services terminating (unplug).
                var termIter: io_iterator_t = 0
                if IOServiceAddMatchingNotification(
                    port, kIOTerminatedNotification, IOServiceMatching(className),
                    terminateCallback, contextPtr, &termIter
                ) == KERN_SUCCESS {
                    matchedIterators.append(termIter)
                    handleTerminated(termIter)  // arm
                }
            }
            isArming = false
        }
    }

    // Must not be called from `queue` (the notifier's own dispatch queue):
    // the drain barrier below would deadlock waiting on itself. Callers are
    // the app main thread (direct call, or via LivePortDataSource.stop()
    // from an AsyncStream onTermination / app-terminate path), never a
    // callback running on `queue`.
    func stop() {
        // Idempotent and thread-safe: this flips stopLock's flag and reports
        // whether it was already set, atomically, so two concurrent stop()
        // calls cannot both pass the guard and both proceed to double
        // destroy the port / double release the WatchContext pointers below.
        let alreadyStopped = stopLock.withLock { stopped -> Bool in
            let was = stopped
            stopped = true
            return was
        }
        guard !alreadyStopped else { return }

        debounceTask?.cancel()
        debounceTask = nil

        // Stop new callbacks first: destroying the port is enough on its own
        // to stop any further callback being scheduled onto `queue`.
        // Deliberately not touching interestNotifications, matchedIterators
        // or portIdentities yet: a callback already running or already
        // enqueued on `queue` reads and mutates those same dictionaries
        // (handleTerminated removes entries, handleMatched/registerInterest
        // inserts), so touching them from this thread before the drain below
        // would race with that callback.
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }

        // Drain barrier: with no new callbacks arriving, this sync waits out
        // any callback that was already running or already enqueued on
        // `queue` before the port was destroyed. Once it returns, nothing
        // else can be touching the dictionaries below, so it's safe to tear
        // them down from this thread.
        queue.sync {}

        // Now safe: release every notification object, the matching
        // iterators, then the WatchContext pointers (balancing the
        // passRetained() taken for each watched class in start()).
        for (_, notification) in interestNotifications {
            IOObjectRelease(notification)
        }
        interestNotifications.removeAll()

        for iter in matchedIterators {
            IOObjectRelease(iter)
        }
        matchedIterators.removeAll()

        for ptr in watchContextPointers {
            Unmanaged<WatchContext>.fromOpaque(ptr).release()
        }
        watchContextPointers.removeAll()
        portIdentities.removeAll()

        onChange = nil
        onLifecycleEvent = nil
    }

    deinit {
        // Guards against the retained WatchContext pointers leaking (and,
        // worse, a callback firing on a destroyed port with this notifier's
        // memory already gone) if a caller drops the last reference without
        // calling stop() first. stop() is idempotent, so this is a no-op
        // when the caller already stopped explicitly.
        stop()
    }

    // A watched service appeared (or, during start, already exists). Register
    // interest on it for future property changes, and signal a change unless
    // we're still arming.
    private func handleMatched(_ iter: io_iterator_t, context: WatchContext, contextPtr: UnsafeMutableRawPointer) {
        var sawService = false
        while case let service = IOIteratorNext(iter), service != 0 {
            registerInterest(for: service, context: context, contextPtr: contextPtr)
            IOObjectRelease(service)
            sawService = true
        }
        if sawService && !isArming {
            scheduleDebounce()
        }
    }

    // A watched service terminated (unplug). Release its interest notification
    // so the table doesn't accumulate stale entries across plug cycles, drop
    // any cached lifecycle identity for it, and signal a change.
    private func handleTerminated(_ iter: io_iterator_t) {
        var sawService = false
        while case let service = IOIteratorNext(iter), service != 0 {
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            if let notification = interestNotifications.removeValue(forKey: entryID) {
                IOObjectRelease(notification)
            }
            portIdentities.removeValue(forKey: entryID)
            IOObjectRelease(service)
            sawService = true
        }
        if sawService && !isArming {
            scheduleDebounce()
        }
    }

    private func registerInterest(for service: io_service_t, context: WatchContext, contextPtr: UnsafeMutableRawPointer) {
        guard let notifyPort else { return }

        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        guard interestNotifications[entryID] == nil else { return }

        // Resolve lifecycle identity once, up front, rather than on every
        // interest callback. Only IOAccessoryManager services that identify
        // as a built-in port get one; everything else is left absent from
        // the cache, which handleInterest treats as "no lifecycle decoding".
        if context.className == "IOAccessoryManager", let identity = resolvePortIdentity(for: service) {
            portIdentities[entryID] = identity
        }

        let interestCallback: IOServiceInterestCallback = { refcon, service, messageType, _ in
            guard let refcon else { return }
            let context = Unmanaged<WatchContext>.fromOpaque(refcon).takeUnretainedValue()
            context.notifier.handleInterest(service: service, className: context.className, messageType: messageType)
        }

        var notification: io_object_t = 0
        let kr = IOServiceAddInterestNotification(
            notifyPort,
            service,
            kIOGeneralInterest,
            interestCallback,
            contextPtr,
            &notification
        )

        if kr == KERN_SUCCESS {
            interestNotifications[entryID] = notification
        }
    }

    // Fires on every interest notification. All watched classes get the
    // debounced refresh (unchanged behaviour for the four transport-state
    // classes); IOAccessoryManager additionally gets a synchronous, non-
    // debounced lifecycle event when the service has a cached port identity
    // and the message type decodes to a known signal.
    private func handleInterest(service: io_service_t, className: String, messageType: UInt32) {
        scheduleDebounce()

        guard className == "IOAccessoryManager" else { return }

        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return }
        guard let identity = portIdentities[entryID] else { return }
        guard let signal = decodeLifecycleMessage(messageType) else { return }

        onLifecycleEvent?(RawPortLifecycleEvent(
            portNumber: identity.portNumber,
            isMagSafe: identity.isMagSafe,
            signal: signal
        ))
    }

    // Identifies a built-in USB-C or MagSafe port from an IOAccessoryManager
    // service, mirroring HPMReader's parse rules (entry name prefix, port
    // type, BuiltIn). Deliberately does not resolve the HPM controller UUID
    // that HPMReader also reads: lifecycle events only need portNumber and
    // isMagSafe, and walking to the controller on every match would be
    // needless work here.
    private func resolvePortIdentity(for service: io_service_t) -> PortIdentity? {
        guard let name = ioEntryName(service), name.hasPrefix("Port-") else { return nil }
        guard let properties = ioProperties(service) else { return nil }

        let portType = ioString(properties["PortTypeDescription"])
        let isRealPort = portType == "USB-C" || portType.hasPrefix("MagSafe")
        guard isRealPort else { return nil }

        // Same "only an explicit false rejects" rule as HPMReader: a missing
        // BuiltIn key must not empty the identity cache.
        if let builtIn = properties["BuiltIn"], !ioBool(builtIn) { return nil }

        guard let portNumber = ioLocationInPlaneInt(service) else { return nil }

        return PortIdentity(portNumber: portNumber, isMagSafe: portType.lowercased().contains("magsafe"))
    }

    // Coalesce rapid-fire notifications into a single callback.
    // A plug event fires ~100 notifications in quick succession.
    // We wait 80ms after the last one before signalling.
    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }
}
