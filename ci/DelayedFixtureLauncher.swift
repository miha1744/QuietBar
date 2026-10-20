import Foundation
import Darwin

private var fixtureStopping = false

@main
struct DelayedFixtureLauncher {
    static func main() {
        guard let control = fixtureControl(), let output = control["outputDirectory"] as? String else { return }
        signal(SIGTERM) { _ in fixtureStopping = true }
        signal(SIGINT) { _ in fixtureStopping = true }
        signal(SIGHUP) { _ in fixtureStopping = true }
        signal(SIGALRM) { _ in fixtureStopping = true }
        alarm(75)
        let helper = fixtureAppPath + "/Contents/Helpers/CaptureFixture"
        let record: [String: Any] = ["pid": getpid(), "parentPID": getppid(),
          "executablePath": fixtureAppPath + "/Contents/MacOS/DelayedFixture", "helperPath": helper,
          "phase": control["phase"] ?? "", "captureStarted": false]
        let destination = URL(fileURLWithPath: output).appendingPathComponent("launcher.json")
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: destination, options: .atomic)
        }
        // No NSApplication is created in this selected app's initial process.
        // The capture helper is born later and remains a normal owned child.
        for _ in 0..<30 { if fixtureStopping { return }; usleep(100_000) }
        var child: pid_t = 0
        var argv = [strdup(helper), nil]
        var environment = ProcessInfo.processInfo.environment.map { strdup($0.key + "=" + $0.value) }
        environment.append(nil)
        let spawned = helper.withCString { executable in
            posix_spawn(&child, executable, nil, nil, &argv, &environment)
        }
        free(argv[0])
        for item in environment { free(item) }
        guard spawned == 0 else { return }
        var status: Int32 = 0
        while true {
            let waited = waitpid(child, &status, WNOHANG)
            if waited == child || waited == -1 { return }
            if fixtureStopping {
                // waitpid==0 means this exact PID is still our unreaped child;
                // it cannot have been reused by an unrelated process.
                _ = kill(child, SIGTERM)
                for _ in 0..<30 {
                    if waitpid(child, &status, WNOHANG) != 0 { return }
                    usleep(100_000)
                }
                if waitpid(child, &status, WNOHANG) == 0 { _ = kill(child, SIGKILL); _ = waitpid(child, &status, 0) }
                return
            }
            usleep(100_000)
        }
    }
}
