import SwiftUI
import Photos
import AppKit

struct ClusterListView: View {
    @State private var status: ScanStatus?
    @State private var clusters: [ClusterSummary] = []
    @State private var selectedCluster: ClusterSummary?
    @State private var errorMessage: String?
    @State private var pollingTask: Task<Void, Never>?
    @State private var sort: ClusterSort = .duplicates

    var body: some View {
        VStack(spacing: 0) {
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
            DeletionBar()
        }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
        // A commit removes photos (and emptied clusters) from the store; refresh
        // the sidebar so group counts and vanished groups update immediately.
        .onChange(of: DeletionQueue.shared.commitGeneration) {
            Task { await reloadAfterCommit() }
        }
        .alert("Error", isPresented: .constant(errorMessage != nil), actions: {
            Button("OK") { errorMessage = nil }
        }, message: {
            Text(errorMessage ?? "")
        })
    }

    @MainActor
    private func reloadAfterCommit() async {
        do {
            clusters = try await LocalBackend.shared.clusters(sort: sort)
            if let sel = selectedCluster, !clusters.contains(where: { $0.id == sel.id }) {
                selectedCluster = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Re-fetches the current groups in the selected sort order without
    /// disturbing the scan/polling lifecycle. Used when the user flips the sort.
    @MainActor
    private func reloadClusters() async {
        guard status?.state == "done" || status?.state == "error" else { return }
        do {
            clusters = try await LocalBackend.shared.clusters(sort: sort)
        } catch {
            errorMessage = error.localizedDescription
        }
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
                // Compact icon-only menu so it doesn't crowd the narrow sidebar
                // toolbar and push the Scan button into the overflow chevron.
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(ClusterSort.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .help("Sort groups by \(sort.label)")

                Button(action: { Task { await startScan() } }) {
                    Label("Scan Library", systemImage: "arrow.clockwise")
                }
                .disabled(status?.state == "running")
            }
        }
        .onChange(of: sort) { Task { await reloadClusters() } }
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

            // Load groups on every poll — including while the scan is still
            // running — so duplicates appear in real time as the live-clustering
            // pass discovers them. Keep polling only while running.
            switch status?.state {
            case "running", "done", "error":
                clusters = try await LocalBackend.shared.clusters(sort: sort)
                print("[ClusterListView] loaded \(clusters.count) clusters (state=\(status?.state ?? "?"))")
            default:
                break
            }
            return status?.state == "running"
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
            // beginScan wipes photos/clusters from the DB; any marks left over
            // from a previous session now point at rows that no longer exist.
            DeletionQueue.shared.clear()

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
            ClusterThumbnail(
                identifier: cluster.representativeIdentifier,
                fallbackUuid: cluster.representativeUuid
            )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if cluster.kind == "study_block" {
                        Image(systemName: "rectangle.stack")
                            .font(AppFont.base).foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(AppFont.label)
                }
                Text(subtitle)
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

    // Prefer the Vision scene label ("Beach, Sky"); fall back to a plain-language
    // description of the group type until captioning has run.
    private var title: String {
        if let caption = cluster.caption, !caption.isEmpty { return caption }
        return kindLabel
    }

    private var kindLabel: String {
        switch cluster.kind {
        case "burst": "Burst Photos"
        case "raw_jpeg": "RAW + JPEG"
        case "live": "Live Photo"
        case "phash": "Similar Photos"
        case "video": "Similar Videos"
        case "study_block": "Study Block"
        default: cluster.kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // Study blocks earn a richer subtitle — capture span and a rough cull count —
    // since their whole point is "here's a long run worth reviewing."
    private var subtitle: String {
        guard cluster.kind == "study_block" else { return "\(cluster.memberCount) photos" }
        var parts = ["\(cluster.memberCount) photos"]
        if let span = cluster.timeSpanSeconds { parts.append(Self.formatSpan(span)) }
        if let redundant = cluster.estimatedRedundant, redundant > 0 {
            parts.append("~\(redundant) to cull")
        }
        return parts.joined(separator: " · ")
    }

    private static func formatSpan(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        if s >= 60 { return "\(s / 60)m" }
        return "\(s)s"
    }
}

/// Tiny sidebar thumbnail of a cluster's representative photo, sized to fit one
/// list row. Loads via PhotoKit from the stored localIdentifier, falling back to
/// the reconstructed identifier form for pre-migration rows.
struct ClusterThumbnail: View {
    let identifier: String?
    let fallbackUuid: String

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.secondary.opacity(0.12)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    )
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        // Load on appear and whenever the row's photo changes. We deliberately
        // do NOT cancel on disappear: a sidebar List briefly appears/disappears
        // rows during layout, and cancelling there kills the async request
        // before the image arrives, leaving the row permanently blank.
        .task(id: identifier ?? fallbackUuid) { load() }
    }

    private func load() {
        image = nil
        let candidates = [identifier, "\(fallbackUuid)/L0/001"].compactMap { $0 }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: candidates, options: nil)
        guard let asset = result.firstObject else { return }

        let opts = PHImageRequestOptions()
        opts.deliveryMode = .fastFormat   // one reliable callback, ideal for a tiny thumb
        opts.isNetworkAccessAllowed = true
        opts.resizeMode = .fast
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let side = 30 * scale
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFill,
            options: opts
        ) { img, _ in
            guard let img else { return }
            DispatchQueue.main.async { self.image = img }
        }
    }
}
