import Foundation
import Darwin

/// Foundation creates a new process group on Darwin. Signal that group only
/// when it is owned by this child; never signal the application's group.
enum ChildProcess {
    static func stop(_ child: Process) {
        guard child.isRunning else { return }
        let pid = child.processIdentifier
        if getpgid(pid) == pid { _ = kill(-pid, SIGTERM) } else { child.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) {
            guard child.isRunning else { return }
            if getpgid(pid) == pid { _ = kill(-pid, SIGKILL) } else { _ = kill(pid, SIGKILL) }
        }
    }
}
