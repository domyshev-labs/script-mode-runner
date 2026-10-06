import Foundation

enum RunnerExitWatchdog {
    static func launch(pid: Int32, action: RunnerAction, executablePath: String,
                       timeoutTicks: Int = 60) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // A separate process can enforce the deadline even if the UI thread is blocked.
        process.arguments = ["-c", """
            count=0
            while kill -0 "$1" 2>/dev/null; do
                if [ "$count" -ge "$4" ]; then
                    kill -KILL "$1" 2>/dev/null
                fi
                count=$((count + 1))
                sleep 0.1
            done
            if [ "$2" = restart ]; then exec "$3"; fi
            """, "mode-runner-exit", String(pid), action.rawValue, executablePath, String(timeoutTicks)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
