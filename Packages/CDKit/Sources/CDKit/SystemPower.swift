import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog

/// Keeps the Mac from idle-sleeping while a CD plays. The display may still sleep.
@MainActor
public protocol SleepPreventing: AnyObject {
    func setActive(_ active: Bool)
}

/// A user-initiated process activity, which `pmset -g assertions` lists as
/// `PreventUserIdleSystemSleep` named "Playing an audio CD".
@MainActor
public final class ProcessActivitySleepPrevention: SleepPreventing {
    private var activity: (any NSObjectProtocol)?
    private let logger = Logger(subsystem: "io.github.ylau674.CDPlayer", category: "Power")

    public nonisolated init() {}

    public func setActive(_ active: Bool) {
        if active, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Playing an audio CD")
            logger.info("Holding off idle sleep while the CD plays")
        } else if !active, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
            logger.info("Idle sleep allowed again")
        }
    }
}

/// Acknowledges a sleep exactly once: when first sent, or when released unsent, so an event that
/// nobody handled never holds sleep up.
final class SleepAcknowledgement: @unchecked Sendable {
    private let lock = NSLock()
    private var acknowledge: (@Sendable () -> Void)?

    init(_ acknowledge: @escaping @Sendable () -> Void) {
        self.acknowledge = acknowledge
    }

    deinit { send() }

    /// Returns whether this call was the one that acknowledged.
    @discardableResult
    func send() -> Bool {
        lock.lock()
        let acknowledge = self.acknowledge
        self.acknowledge = nil
        lock.unlock()
        acknowledge?()
        return acknowledge != nil
    }
}

public enum SystemPowerEvent: Sendable {
    /// The Mac is about to sleep. Call `acknowledge` once ready; macOS waits at most 30 seconds.
    case willSleep(acknowledge: @Sendable () -> Void)
    /// The Mac woke and its devices are powered again.
    case didWake
}

public protocol SystemPowerMonitoring: Sendable {
    /// System sleep and wake, until the stream's consumer stops.
    func events() -> AsyncStream<SystemPowerEvent>
}

/// Listens to IOKit's root power domain. Unlike `NSWorkspace.willSleepNotification`, this lets
/// sleep wait for a pause that finishes asynchronously.
public final class SystemPowerMonitor: SystemPowerMonitoring {
    public init() {}

    public func events() -> AsyncStream<SystemPowerEvent> {
        // Unbounded: a dropped `willSleep` could never be acknowledged.
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            guard let registration = SystemPowerRegistration(continuation: continuation) else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in registration.close() }
        }
    }
}

/// Turns root-domain messages into events. Every sleep is allowed: at once when macOS only asks,
/// otherwise when the event is acknowledged, or immediately if nothing listens any more.
struct SystemPowerMessages: Sendable {
    // <IOKit/IOMessage.h> builds these with iokit_common_msg(), which Swift does not import.
    static let canSystemSleep: natural_t = 0xE000_0270
    static let systemWillSleep: natural_t = 0xE000_0280
    static let systemHasPoweredOn: natural_t = 0xE000_0300

    let continuation: AsyncStream<SystemPowerEvent>.Continuation
    let allow: @Sendable (Int) -> Void

    func handle(_ message: natural_t, notificationID: Int) {
        switch message {
        case Self.canSystemSleep:
            allow(notificationID)
        case Self.systemWillSleep:
            let allow = self.allow
            let acknowledgement = SleepAcknowledgement { allow(notificationID) }
            if case .terminated = continuation.yield(.willSleep(acknowledge: { acknowledgement.send() })) {
                acknowledgement.send()
            }
        case Self.systemHasPoweredOn:
            continuation.yield(.didWake)
        default:
            break
        }
    }
}

/// One IOKit registration. Messages arrive on `queue`, which also closes the registration, so
/// none can arrive once it is released.
private final class SystemPowerRegistration: @unchecked Sendable {
    private static let logger = Logger(subsystem: "io.github.ylau674.CDPlayer", category: "Power")
    private let queue = DispatchQueue(label: "io.github.ylau674.CDPlayer.system-power", qos: .userInitiated)
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?
    private var messages: SystemPowerMessages?

    init?(continuation: AsyncStream<SystemPowerEvent>.Continuation) {
        // Released by `close()`, after the last message can arrive.
        let context = Unmanaged.passRetained(self)
        var port: IONotificationPortRef?
        var notifier: io_object_t = 0
        let rootPort = IORegisterForSystemPower(context.toOpaque(), &port, systemPowerMessage, &notifier)
        guard rootPort != 0, let port else {
            context.release()
            Self.logger.error("Cannot register for system sleep and wake notifications")
            return nil
        }
        self.rootPort = rootPort
        self.notifier = notifier
        self.port = port
        messages = SystemPowerMessages(continuation: continuation) { _ = IOAllowPowerChange(rootPort, $0) }
        IONotificationPortSetDispatchQueue(port, queue)
    }

    fileprivate func receive(_ message: natural_t, notificationID: Int) {
        messages?.handle(message, notificationID: notificationID)
    }

    func close() {
        queue.async { [self] in
            guard let port else { return }
            self.port = nil
            messages = nil
            IONotificationPortSetDispatchQueue(port, nil)
            IODeregisterForSystemPower(&notifier)
            IOServiceClose(rootPort)
            IONotificationPortDestroy(port)
            Unmanaged.passUnretained(self).release()
        }
    }
}

private func systemPowerMessage(
    _ context: UnsafeMutableRawPointer?, _ service: io_service_t, _ message: natural_t,
    _ argument: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    Unmanaged<SystemPowerRegistration>.fromOpaque(context).takeUnretainedValue()
        .receive(message, notificationID: Int(bitPattern: argument))
}
