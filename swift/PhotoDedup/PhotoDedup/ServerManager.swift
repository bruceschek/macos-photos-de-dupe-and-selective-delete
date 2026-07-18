import Foundation
import Observation

@MainActor
@Observable
final class ServerManager {
    static let shared = ServerManager()

    enum State {
        case notStarted
        case launching
        case ready
        case failed(String)
    }

    var state: State = .notStarted

    private var process: Process?

    // Stored in UserDefaults so the user can override if they move the project
    var pythonProjectPath: String {
        get {
            UserDefaults.standard.string(forKey: "pythonProjectPath") ?? Self.defaultPythonPath
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "pythonProjectPath")
        }
    }

    nonisolated static var defaultPythonPath: String {
        let home = NSHomeDirectory()
        return "\(home)/dev/swift/012-photo-app-de-dupe-and-deletion/python/ml"
    }

    func startIfNeeded() async {
        guard case .notStarted = state else { return }

        let projectPath = pythonProjectPath
        guard FileManager.default.fileExists(atPath: projectPath) else {
            state = .failed("Python project not found at:\n\(projectPath)\n\nUpdate the path in Settings.")
            return
        }

        // Xcode stopping the Swift app does not always terminate child processes.
        guard terminateStaleBackendIfOwned(projectPath: projectPath) else {
            state = .failed("Port 8765 is already in use by another process.\n\nStop that process or change the backend port before launching Photo Dedup.")
            return
        }

        state = .launching

        guard let uvPath = findUV() else {
            state = .failed("Could not find the 'uv' binary.\n\nInstall it from https://docs.astral.sh/uv/ or set the correct path in Settings.")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: uvPath)
        proc.arguments = ["run", "python", "main.py"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectPath)

        // Pipe Python stdout+stderr → Xcode console
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                print("[Python]", text, terminator: "")
            }
        }

        print("[ServerManager] Launching: \(uvPath) run python main.py")
        print("[ServerManager] Working dir: \(projectPath)")

        do {
            try proc.run()
        } catch {
            state = .failed("Failed to launch backend: \(error.localizedDescription)")
            return
        }

        process = proc
        print("[ServerManager] Process launched (pid \(proc.processIdentifier))")

        // Poll up to 60 seconds for the server to respond
        for attempt in 1...60 {
            try? await Task.sleep(for: AppConstants.serverStartupPollInterval)
            if await isServerReachable() {
                print("[ServerManager] Server ready after \(attempt)s")
                state = .ready
                return
            }
            if !proc.isRunning {
                print("[ServerManager] Process exited with status \(proc.terminationStatus)")
                state = .failed("Backend process exited unexpectedly (status \(proc.terminationStatus)).\n\nCheck the Xcode console for Python output.\n\nAlso run in terminal to verify:\n  cd python/ml && uv run python main.py")
                return
            }
            if attempt % 5 == 0 {
                print("[ServerManager] Still waiting… (\(attempt)s)")
            }
        }

        state = .failed("Backend did not respond within 60 seconds.")
    }

    func stop() {
        process?.terminate()
        process = nil
        state = .notStarted
    }

    func retry() async {
        stop()
        await startIfNeeded()
    }

    private func isServerReachable() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8765/status") else { return false }
        do {
            let (_, resp) = try await URLSession.shared.data(from: url)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func terminateStaleBackendIfOwned(projectPath: String) -> Bool {
        let output = commandOutput(
            executable: "/usr/sbin/lsof",
            arguments: ["-t", "-iTCP:8765", "-sTCP:LISTEN"]
        )
        let pids = Set(output.split(whereSeparator: \.isNewline).map(String.init))
        guard !pids.isEmpty else { return true }

        var foundForeignListener = false
        for pid in pids {
            if isOwnedBackendProcess(pid: pid, projectPath: projectPath) {
                _ = commandOutput(executable: "/bin/kill", arguments: ["-TERM", pid])
                print("[ServerManager] Terminated stale backend on port 8765 (pid \(pid))")
            } else {
                print("[ServerManager] Port 8765 is in use by pid \(pid), but it is not this backend; leaving it alone")
                foundForeignListener = true
            }
        }
        return !foundForeignListener
    }

    private func isOwnedBackendProcess(pid: String, projectPath: String) -> Bool {
        let expectedCWD = URL(fileURLWithPath: projectPath).standardizedFileURL.path
        let cwdOutput = commandOutput(
            executable: "/usr/sbin/lsof",
            arguments: ["-a", "-p", pid, "-d", "cwd", "-Fn"]
        )
        let cwd = cwdOutput
            .split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("n") }
            .map { String($0.dropFirst()) }

        let command = commandOutput(
            executable: "/bin/ps",
            arguments: ["-p", pid, "-o", "command="]
        )

        guard cwd == expectedCWD else { return false }
        return command.contains("main.py")
            && (command.contains("python") || command.contains("uv"))
    }

    private func commandOutput(executable: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private func findUV() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/uv",
            "/usr/local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/bin/uv",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}
