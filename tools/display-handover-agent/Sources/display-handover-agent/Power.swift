import Foundation
import IOKit
import IOKit.pwr_mgt

/// Follows the IOKit sleep and wake protocol of Apple QA1340
@MainActor
final class PowerMonitor {
    private(set) var sleeping = false
    private(set) var lastWake: Date?
    /// Refuses idle sleep and delays a forced sleep (macOS allows up to 30 s), so a display action
    /// and its confirmation can finish before the sleep.
    var holdsSleep = false {
        didSet {
            guard !holdsSleep, let pending = pendingSleep else { return }
            pendingSleep = nil
            IOAllowPowerChange(rootPort, pending)
        }
    }
    private var pendingSleep: Int?
    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var port: IONotificationPortRef?

    // iokit_common_msg() values from IOKit/IOMessage.h, which Swift does not import
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &port, { context, _, message, argument in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.handle(message, argument) }
        }, &notifier)
        guard rootPort != 0, let port else {
            Log.error("could not register for sleep and wake notifications")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)
    }

    private func handle(_ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch message {
        case Self.canSystemSleep:
            if holdsSleep {
                IOCancelPowerChange(rootPort, Int(bitPattern: argument))
            } else {
                IOAllowPowerChange(rootPort, Int(bitPattern: argument))
            }
        case Self.systemWillSleep:
            sleeping = true
            if holdsSleep {
                pendingSleep = Int(bitPattern: argument)
                Log.info("system going to sleep once the display action ends")
            } else {
                Log.info("system going to sleep")
                IOAllowPowerChange(rootPort, Int(bitPattern: argument))
            }
        case Self.systemHasPoweredOn:
            pendingSleep = nil  // macOS went ahead after 30 s without the acknowledgement
            sleeping = false
            lastWake = Date()
            Log.info("system woke up")
        default:
            break
        }
    }
}
