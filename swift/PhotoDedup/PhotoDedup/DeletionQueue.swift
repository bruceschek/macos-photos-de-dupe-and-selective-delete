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

    private var markedUUIDs: Set<String> = []
    private static let logLimit = 500

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

    /// Deletes every marked photo in a single PhotoKit call. On success the
    /// queue clears, the deleted rows are removed from the local store, and
    /// `lastCommitUUIDs` is published for views to drop. Cancelling the system
    /// dialog throws, leaving the queue intact so nothing is lost.
    func commit() async {
        guard !marked.isEmpty, !isCommitting else { return }
        isCommitting = true
        defer { isCommitting = false }

        let items = marked
        let fetch = PHAsset.fetchAssets(
            withLocalIdentifiers: items.map(\.localIdentifier), options: nil)
        var assets: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in assets.append(asset) }

        // Assets that no longer resolve are already gone from Photos; only make
        // the (crash-prone) PhotoKit call when there's something real to delete.
        if !assets.isEmpty {
            do {
                try await Self.deleteAssets(assets)
            } catch {
                lastError = error.localizedDescription
                return
            }
        }

        let deletedUUIDs = Set(items.map(\.uuid))
        committedLog.insert(contentsOf: items, at: 0)
        if committedLog.count > Self.logLimit {
            committedLog.removeLast(committedLog.count - Self.logLimit)
        }
        clear()
        await LocalBackend.shared.removePhotos(uuids: Array(deletedUUIDs))
        lastCommitUUIDs = deletedUUIDs
        commitGeneration += 1
    }

    /// performChanges:completionHandler: crashes with _dispatch_assert_queue_fail
    /// when the Photos daemon returns com.apple.accounts Code=7 during changes
    /// execution — the crash happens before the completion handler is called, so
    /// dispatching to main there can't save us. performChangesAndWait throws an
    /// NSError in the same condition instead of crashing. Run it off the main
    /// thread so it doesn't block the UI while Photos commits.
    private nonisolated static func deleteAssets(_ assets: [PHAsset]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try PHPhotoLibrary.shared().performChangesAndWait {
                        PHAssetChangeRequest.deleteAssets(assets as NSArray)
                    }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
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
