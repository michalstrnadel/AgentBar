import Foundation
import IOKit.pwr_mgt

/// Puts the Mac to sleep now — "Sleep When Agents Are Done". The same request the
/// Apple menu's Sleep makes, through IOKit; `pmset sleepnow` is the fallback,
/// which needs no administrator rights either.
enum SystemSleep {
    @discardableResult
    static func now() -> Bool {
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        if port != 0 {
            defer { IOServiceClose(port) }
            if IOPMSleepSystem(port) == kIOReturnSuccess { return true }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["sleepnow"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            return true
        } catch {
            return false
        }
    }
}
