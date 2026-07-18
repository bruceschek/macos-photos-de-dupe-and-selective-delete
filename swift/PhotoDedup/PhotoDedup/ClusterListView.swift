import SwiftUI

struct ClusterListView: View {
    @State private var status: ScanStatus?
    @State private var clusters: [ClusterSummary] = []
    @State private var selectedCluster: ClusterSummary?
    @State private var errorMessage: String?
    @State private var pollingTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            if let selected = selectedCluster {
                ClusterDetailView(clusterId: selected.id)
            } else {
                ContentUnavailableView("Select a Group", systemImage: "photo.on.rectangle.angled",
                    description: Text("Choose a duplicate group from the sidebar to review photos side by side."))
            }
        }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
        .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "")
        })
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            if let s = status {
                ScanStatusBanner(status: s)
                Divider()
            }
            if clusters.isEmpty && status?.state == "done" {
                ContentUnavailableView("No Duplicates Found", systemImage: "checkmark.circle",
                    description: Text("Your library is clean, or a scan hasn't run yet."))
            } else if let s = status, clusters.isEmpty, s.state != "running" {
                // Fresh database (first run of the native backend) — nothing
                // to show until a scan populates it.
                ContentUnavailableView {
                    Label("No Scan Yet", systemImage: "photo.stack")
                } description: {
                    Text("Scan your library to find duplicate photos and videos.")
                } actions: {
                    Button("Scan Library") { Task { await startScan() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List(clusters, selection: $selectedCluster) { cluster in
                    ClusterRow(cluster: cluster).tag(cluster)
                }
                .listStyle(.sidebar)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if status?.state == "running" {
                    ProgressView().scaleEffect(0.7)
                }
                Button(action: { Task { await startScan() } }) {
                    Label("Scan Library", systemImage: "arrow.clockwise")
                }
                .disabled(status?.state == "running")
            }
        }
        .navigationTitle("Groups (\(clusters.count))")
    }

    @MainActor
    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor in
            await refreshUntilSettled()
        }
    }

    @MainActor
    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    @MainActor
    private func refreshUntilSettled() async {
        while !Task.isCancelled {
            let shouldContinue = await refreshOnce()
            guard shouldContinue else { break }

            do {
                try await Task.sleep(for: AppConstants.statusPollingInterval)
            } catch {
                break
            }
        }
    }

    @MainActor
    @discardableResult
    private func refreshOnce() async -> Bool {
        print("[ClusterListView] refresh() called")
        do {
            status = try await LocalBackend.shared.status()
            print("[ClusterListView] status: state=\(status?.state ?? "nil"), total=\(status?.totalPhotos ?? 0), scanned=\(status?.scanned ?? 0)")
            if let err = status?.error { print("[ClusterListView] scan error: \(err)") }

            if status?.state == "done" {
                clusters = try await LocalBackend.shared.clusters()
                print("[ClusterListView] loaded \(clusters.count) clusters")
            } else if status?.state == "error" {
                clusters = try await LocalBackend.shared.clusters()
                print("[ClusterListView] loaded \(clusters.count) clusters (partial, scan errored)")
            } else if status?.state == "running" {
                return true
            }
        } catch {
            print("[ClusterListView] network error: \(error)")
            errorMessage = error.localizedDescription
        }
        return false
    }

    @MainActor
    private func startScan() async {
        print("[ClusterListView] startScan() — using PhotoLibraryBridge")
        do {
            try await LocalBackend.shared.beginScan()
            clusters = []
            selectedCluster = nil

            startPolling()

            try await PhotoLibraryBridge.shared.enumerateAndIngest()
        } catch {
            print("[ClusterListView] startScan error: \(error)")
            errorMessage = error.localizedDescription
        }
        startPolling()
    }
}

struct ScanStatusBanner: View {
    let status: ScanStatus
    private var bridge: PhotoLibraryBridge { PhotoLibraryBridge.shared }

    // Cached ETA string — updated at most once every AppConstants.etaRefreshInterval
    @State private var displayedETA: String?
    @State private var lastETARefresh: Date = .distantPast

    // Pure math: what would the ETA be right now?
    private var computedETA: String? {
        guard status.state == "running", status.totalPhotos > 0, status.scanned > 0 else { return nil }
        // Require at least 5 s of elapsed time so the early rate estimate is stable
        guard let elapsed = status.elapsedSeconds, elapsed > 5 else { return nil }

        let remaining = max(status.totalPhotos - status.scanned, 0)
        // During the ingestion phase the backend reports scanned == totalPhotos,
        // making remaining = 0.  Hide the estimate rather than show "~0s".
        guard remaining > 0 else { return nil }

        let rate = Double(status.scanned) / elapsed // items per second
        guard rate > 0.0001 else { return nil }
        let remainingSeconds = Double(remaining) / rate

        // Suppress implausibly small values — if the math says we're <10 s from done
        // but we're still in "running" state, the sample window is too noisy to trust.
        guard remainingSeconds >= 10 else { return nil }

        return formatDuration(remainingSeconds)
    }

    /// Refreshes `displayedETA` only if the throttle window has elapsed.
    private func refreshETAIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastETARefresh) >= AppConstants.etaRefreshInterval else { return }
        displayedETA = computedETA
        lastETARefresh = now
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let hours = s / 3600
        let minutes = (s % 3600) / 60
        let secs = s % 60
        if hours > 0 {
            return "~\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "~\(minutes)m \(secs)s"
        } else {
            return "~\(secs)s"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(stateColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(bannerTitle).font(AppFont.base.bold())
                if status.totalPhotos > 0 && status.state == "running" {
                    ProgressView(value: Double(status.scanned), total: Double(status.totalPhotos))
                        .progressViewStyle(.linear)
                    Text("\(status.scanned) / \(status.totalPhotos) · \(status.skippedCloud) skipped")
                        .font(AppFont.small).foregroundStyle(.secondary)
                    if let eta = displayedETA {
                        Text("ETA: \(eta)")
                            .font(AppFont.small)
                            .foregroundStyle(.secondary)
                    }
                } else if status.state == "done" {
                    Text("\(status.totalPhotos) photos · \(status.clustersFound) groups found")
                        .font(AppFont.small).foregroundStyle(.secondary)
                } else if status.state == "error", let msg = status.error {
                    Text(msg).font(AppFont.small).foregroundStyle(.red)
                        .lineLimit(4).textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear { refreshETAIfNeeded() }
        .onChange(of: status.scanned) { refreshETAIfNeeded() }
        .onChange(of: status.state) { _, newState in
            // Clear stale ETA as soon as the scan finishes or errors
            if newState != "running" { displayedETA = nil }
        }
    }

    private var bannerTitle: String {
        if case .ingesting = bridge.phase { return "Ingesting" }
        return status.state.capitalized
    }

    private var stateColor: Color {
        switch status.state {
        case "running": .orange
        case "done": .green
        case "error": .red
        default: .gray
        }
    }
}

struct ClusterRow: View {
    let cluster: ClusterSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kindIcon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(cluster.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(AppFont.label)
                Text("\(cluster.memberCount) photos")
                    .font(AppFont.base).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(Int(cluster.confidence * 100))%")
                .font(AppFont.base.monospacedDigit())
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary).clipShape(Capsule())
        }
        .padding(.vertical, 2)
    }

    private var kindIcon: String {
        switch cluster.kind {
        case "burst": "camera.burst"
        case "raw_jpeg": "doc.richtext"
        case "live": "livephoto"
        case "phash": "photo.on.rectangle"
        default: "questionmark.circle"
        }
    }
}
