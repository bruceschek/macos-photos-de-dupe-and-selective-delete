import SwiftUI

@main
struct PhotoDedupApp: App {
    init() {
        // Native backend is the default; the Python path is opt-in via Settings.
        UserDefaults.standard.register(defaults: [CurrentBackend.useLocalBackendKey: true])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Root routing view

struct RootView: View {
    @AppStorage(CurrentBackend.useLocalBackendKey) private var useLocalBackend = true
    private let server = ServerManager.shared

    var body: some View {
        if useLocalBackend {
            ClusterListView()
                .onAppear { server.stop() }   // no Python process in native mode
        } else {
            remoteBody
        }
    }

    private var remoteBody: some View {
        Group {
            switch server.state {
            case .notStarted, .launching:
                LaunchingView()
            case .ready:
                ClusterListView()
            case .failed(let message):
                ServerErrorView(message: message)
            }
        }
        .task { await server.startIfNeeded() }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(CurrentBackend.useLocalBackendKey) private var useLocalBackend = true
    @AppStorage("pythonProjectPath") private var pythonProjectPath = ServerManager.defaultPythonPath

    var body: some View {
        Form {
            Section("Backend") {
                Toggle("Use native Swift backend", isOn: $useLocalBackend)
                Text(useLocalBackend
                     ? "Scanning, hashing, and clustering run inside the app. Python is not required."
                     : "The app launches the Python FastAPI backend and talks to it over HTTP. Requires 'uv'.")
                    .font(AppFont.small)
                    .foregroundStyle(.secondary)
            }
            if !useLocalBackend {
                Section("Python") {
                    TextField("Project path", text: $pythonProjectPath)
                    Text("Folder containing main.py — launched with 'uv run python main.py'.")
                        .font(AppFont.small)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
    }
}

// MARK: - Launch screen

struct LaunchingView: View {
    private let server = ServerManager.shared
    @State private var dots = ""
    @State private var dotTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Starting Python backend\(dots)")
                .font(.title3)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .animation(.none, value: dots)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { startDotAnimation() }
        .onDisappear { dotTask?.cancel() }
    }

    private func startDotAnimation() {
        dotTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: AppConstants.dotAnimationInterval)
                dots = dots.count < 3 ? dots + "." : ""
            }
        }
    }
}

// MARK: - Error screen

struct ServerErrorView: View {
    let message: String
    private let server = ServerManager.shared

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Backend Failed to Start")
                .font(.title2.bold())
            Text(message)
                .font(AppFont.label)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            HStack(spacing: 12) {
                Button("Retry") { Task { await server.retry() } }
                    .buttonStyle(.borderedProminent)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
