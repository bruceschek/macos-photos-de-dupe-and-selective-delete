import SwiftUI
import Photos

/// Deferred-deletion queue. Marking a photo is instant, local, and reversible —
/// no PhotoKit call, so no per-photo system dialog. `commit()` deletes the whole
/// batch in ONE `PHAssetChangeRequest`, which means macOS shows its mandatory
/// deletion confirmation exactly once for the entire batch instead of once per
/// photo. This is the only lever available: the system dialog cannot be
/// suppressed, but it is charged per `performChanges` call, not per asset.
@MainActor
@Observable
final class DeletionQueue {
    static let shared = DeletionQueue()

    struct Item: Identifiable, Equatable {
        let uuid: String
        let localIdentifier: String
        let filename: String
        var id: String { uuid }
    }

    private(set) var marked: [Item] = []
    private(set) var committedLog: [Item] = []   // this session, newest first
    private(set) var lastError: String?
    private(set) var isCommitting = false

    /// UUIDs removed by the most recent commit, plus a counter that changes on
    /// every commit so views can react even to an identical set. Views observe
    /// `commitGeneration` and read `lastCommitUUIDs` to drop deleted rows.
    private(set) var lastCommitUUIDs: Set<String> = []
    private(set) var commitGeneration = 0

    /// Set when a PhotoKit call exceeded its watchdog. The blocked call cannot
    /// be cancelled — its thread stays parked inside the XPC reply — so the one
    /// safe response is to stop issuing new ones rather than stack up more
    /// stuck transactions against an already-wedged daemon.
    private(set) var libraryUnresponsive = false

    private var markedUUIDs: Set<String> = []
    private static let logLimit = 500

    /// Assets per `performChangesAndWait`. A commit holds a write transaction
    /// against the Photos database for its whole duration, so one enormous
    /// request means one enormous window in which a crash or a wedge leaves
    /// the library mid-transaction — exactly the state that strands a
    /// `Photos.sqlite.lock` behind. Chunking bounds that window. The cost is
    /// one system confirmation dialog per chunk instead of one overall, which
    /// only bites on batches larger than this.
    private static let maxBatchSize = 500

    /// Watchdog for a single chunk's `performChangesAndWait`. Generous — a
    /// large delete against iCloud is legitimately slow — but finite, so a
    /// wedged `photolibraryd` surfaces as an error instead of a frozen app.
    private static let commitTimeout: Duration = .seconds(180)

    /// Watchdog for the pre-flight probe. `PHPhotoLibrary.shared()` makes the
    /// same synchronous XPC call to `photolibraryd` that hangs Photos.app when
    /// that daemon's per-user state is wedged, so probing it cheaply before
    /// opening a transaction turns "app freezes forever" into a message.
    private static let preflightTimeout: Duration = .seconds(10)

    var count: Int { marked.count }
    func isMarked(_ uuid: String) -> Bool { markedUUIDs.contains(uuid) }

    // MARK: - Marking (instant, reversible)

    /// Marks a photo for later deletion. Returns false (and sets `lastError`)
    /// only if the asset has no PhotoKit identifier and therefore can't be
    /// deleted at all.
    @discardableResult
    func mark(_ photo: PhotoMeta) -> Bool {
        guard let identifier = photo.localIdentifier else {
            lastError = "\(photo.filename) has no PhotoKit identifier and can't be deleted. Re-scan and try again."
            return false
        }
        guard !markedUUIDs.contains(photo.uuid) else { return true }
        marked.append(Item(uuid: photo.uuid, localIdentifier: identifier, filename: photo.filename))
        markedUUIDs.insert(photo.uuid)
        return true
    }

    func toggle(_ photo: PhotoMeta) {
        if markedUUIDs.contains(photo.uuid) { unmark(photo.uuid) } else { mark(photo) }
    }

    func unmark(_ uuid: String) {
        guard markedUUIDs.remove(uuid) != nil else { return }
        marked.removeAll { $0.uuid == uuid }
    }

    /// Reverses the most recent mark — the ⌘Z of rapid-fire marking.
    func unmarkLast() {
        guard let last = marked.popLast() else { return }
        markedUUIDs.remove(last.uuid)
    }

    func clear() {
        marked.removeAll()
        markedUUIDs.removeAll()
    }

    func clearError() { lastError = nil }

    // MARK: - Commit (one system dialog for the whole batch)

    /// Deletes every marked photo, in chunks of `maxBatchSize`. On success the
    /// queue clears, the deleted rows are removed from the local store, and
    /// `lastCommitUUIDs` is published for views to drop. Cancelling the system
    /// dialog throws, leaving the remaining queue intact so nothing is lost.
    ///
    /// Chunks commit independently: if chunk 3 of 5 fails, the first two stay
    /// deleted and only their photos leave the queue. A partial commit is
    /// reported as an error with the surviving marks still in place.
    func commit() async {
        guard !marked.isEmpty, !isCommitting else { return }
        guard !libraryUnresponsive else {
            lastError = "The Photos library stopped responding earlier in this session. "
                + "Quit and reopen Photo Dedup, and make sure Photos.app opens normally, before deleting."
            return
        }
        isCommitting = true
        defer { isCommitting = false }

        // Pre-flight: confirm photolibraryd answers at all before opening any
        // transaction. Cheap, and it fails in ten seconds instead of hanging.
        do {
            try await Self.withTimeout(Self.preflightTimeout) { try Self.probeLibrary() }
        } catch {
            libraryUnresponsive = true
            lastError = "The Photos library isn't responding, so nothing was deleted. "
                + "Your \(marked.count) marked photo\(marked.count == 1 ? "" : "s") "
                + "\(marked.count == 1 ? "is" : "are") still marked. Try opening Photos.app first."
            return
        }

        var deleted: [Item] = []
        var failure: String?

        for chunk in stride(from: 0, to: marked.count, by: Self.maxBatchSize) {
            let items = Array(marked[chunk..<min(chunk + Self.maxBatchSize, marked.count)])
            let identifiers = items.map(\.localIdentifier)
            do {
                try await Self.withTimeout(Self.commitTimeout) {
                    try Self.deleteAssets(withIdentifiers: identifiers)
                }
            } catch is TimeoutError {
                libraryUnresponsive = true
                failure = "Photos stopped responding partway through. "
                    + "\(deleted.count) photo\(deleted.count == 1 ? "" : "s") deleted; the rest are still marked."
                break
            } catch {
                failure = error.localizedDescription
                break
            }
            deleted.append(contentsOf: items)
        }

        guard !deleted.isEmpty else {
            lastError = failure
            return
        }

        let deletedUUIDs = Set(deleted.map(\.uuid))
        committedLog.insert(contentsOf: deleted, at: 0)
        if committedLog.count > Self.logLimit {
            committedLog.removeLast(committedLog.count - Self.logLimit)
        }
        for uuid in deletedUUIDs { unmark(uuid) }
        await LocalBackend.shared.removePhotos(uuids: Array(deletedUUIDs))
        lastCommitUUIDs = deletedUUIDs
        commitGeneration += 1
        lastError = failure
    }

    // MARK: - PhotoKit plumbing

    struct TimeoutError: Error {}

    /// Races `operation` against a deadline. The underlying PhotoKit calls are
    /// synchronous and uncancellable, so losing the race leaks one blocked
    /// background thread — deliberate: the alternative is a permanently frozen
    /// UI. `libraryUnresponsive` then stops us from leaking a second one.
    private nonisolated static func withTimeout(
        _ duration: Duration,
        operation: @escaping @Sendable () throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        do { try operation(); cont.resume() }
                        catch { cont.resume(throwing: error) }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Minimal "is photolibraryd alive" probe: resolve the shared library and
    /// ask it one trivial question. Both go over the same XPC connection a
    /// delete would use.
    private nonisolated static func probeLibrary() throws {
        _ = PHPhotoLibrary.shared()
        let options = PHFetchOptions()
        options.fetchLimit = 1
        _ = PHAsset.fetchAssets(with: .image, options: options).count
    }

    /// Resolves and deletes one chunk, entirely on the calling (background)
    /// thread — identifiers cross the isolation boundary rather than `PHAsset`s,
    /// which keeps the synchronous fetch off the main actor too.
    ///
    /// Identifiers that no longer resolve are already gone from Photos, so an
    /// empty fetch is success, not an error.
    ///
    /// performChanges:completionHandler: crashes with _dispatch_assert_queue_fail
    /// when the Photos daemon returns com.apple.accounts Code=7 during changes
    /// execution — the crash happens before the completion handler is called, so
    /// dispatching to main there can't save us. performChangesAndWait throws an
    /// NSError in the same condition instead of crashing.
    private nonisolated static func deleteAssets(withIdentifiers identifiers: [String]) throws {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard !assets.isEmpty else { return }
        try PHPhotoLibrary.shared().performChangesAndWait {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }
}

// MARK: - App-wide commit bar

/// Persistent bar shown at the bottom of the window whenever photos are marked
/// for deletion. Marking is silent and reversible; `Delete` performs the single
/// batched PhotoKit call, so macOS shows its mandatory confirmation once for the
/// whole batch. Sits below the NavigationSplitView so marks made in any cluster
/// accumulate here and commit together.
struct DeletionBar: View {
    @State private var queue = DeletionQueue.shared
    @State private var showError = false

    var body: some View {
        if queue.count > 0 {
            Divider()
            HStack(spacing: 12) {
                Image(systemName: "trash.fill").foregroundStyle(.red)
                Text("\(queue.count) marked for deletion")
                    .font(AppFont.base.bold())

                Spacer()

                Button("Undo Last") { queue.unmarkLast() }
                    .disabled(queue.isCommitting)
                Button("Clear") { queue.clear() }
                    .disabled(queue.isCommitting)

                Button(role: .destructive) {
                    Task { await queue.commit() }
                } label: {
                    if queue.isCommitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Delete \(queue.count)", systemImage: "trash")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(queue.isCommitting)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .onChange(of: queue.lastError) { _, newValue in
                showError = newValue != nil
            }
            .alert("Delete Error", isPresented: $showError) {
                Button("OK") { queue.clearError() }
            } message: {
                Text(queue.lastError ?? "")
            }
        }
    }
}
