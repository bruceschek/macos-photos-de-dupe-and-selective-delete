import Foundation
import GRDB
import os
import Photos
import AppKit

enum LocalBackendError: Error, LocalizedError {
    case clusterNotFound(Int)

    var errorDescription: String? {
        switch self {
        case .clusterNotFound(let id): "Cluster \(id) not found"
        }
    }
}

private struct HashCandidate: Sendable {
    let uuid: String
    let localIdentifier: String
}

/// Native scan/hash/cluster engine, backed by `PhotoStore` (GRDB). Ingests
/// metadata from `PhotoLibraryBridge`, hashes via `PHash`, and clusters via
/// `Clusterer` (all five cluster kinds).
actor LocalBackend {
    static let shared = LocalBackend()

    private struct ScanState {
        var state = "idle"          // idle | ingesting | hashing | clustering | done | error
        var totalPhotos = 0
        var ingested = 0
        var scanned = 0
        var skippedCloud = 0
        var error: String?
        var scanStartTime: Double?
    }

    private let store = PhotoStore.shared
    private var state = ScanState()
    private var pipelineTask: Task<Void, Never>?
    private var pipelineGeneration = 0

    // Streaming-pipeline coordination (all actor-isolated)
    private var candidateCursor = 0
    private var candidateTotal = 0
    private var pendingHashWrites: [(uuid: String, primary: String, variants: String)] = []
    private var pipelineFailure: Error?

    private static let writeBatchSize = 200
    private let signposter = OSSignposter(
        subsystem: "com.bruceschechter.PhotoDedup", category: "Scan")

    func beginScan() async throws {
        pipelineGeneration += 1
        pipelineTask?.cancel()
        pipelineTask = nil
        try await store.write { db in
            try db.execute(sql: "DELETE FROM cluster_members")
            try db.execute(sql: "DELETE FROM clusters")
            try db.execute(sql: "DELETE FROM photos")
        }
        state = ScanState(state: "ingesting", scanStartTime: Date().timeIntervalSince1970)
    }

    func ingestBatch(_ records: [PhotoRecord]) async throws {
        let now = Date().timeIntervalSince1970
        try await store.write { db in
            for r in records {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO photos
                      (uuid, local_identifier, filename, original_filename, date_taken, burst_uuid,
                       is_raw, is_live, width, height, is_local, file_path,
                       media_type, duration, scanned_at)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """, arguments: StatementArguments([
                        r.uuid, r.localIdentifier, r.filename, r.originalFilename, r.dateTaken, r.burstUuid,
                        r.isRaw, r.isLive, r.width, r.height, r.isLocal, r.filePath,
                        r.mediaType, r.duration, now,
                    ] as [(any DatabaseValueConvertible)?]))
            }
        }
        let ingested = try await store.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photos") ?? 0
        }
        state.ingested = ingested
        state.totalPhotos = ingested
    }

    /// Removes committed-deleted photos from the store so they don't reappear
    /// on the next cluster load. `cluster_members` rows cascade with the photo;
    /// clusters left with fewer than two members are no longer duplicates and
    /// are dropped too, so emptied groups vanish from the list.
    func removePhotos(uuids: [String]) async {
        guard !uuids.isEmpty else { return }
        try? await store.write { db in
            for uuid in uuids {
                try db.execute(sql: "DELETE FROM photos WHERE uuid = ?", arguments: [uuid])
            }
            try db.execute(sql: """
                DELETE FROM clusters WHERE id IN (
                    SELECT c.id FROM clusters c
                    LEFT JOIN cluster_members cm ON cm.cluster_id = c.id
                    GROUP BY c.id HAVING COUNT(cm.photo_uuid) < 2
                )
                """)
        }
    }

    func startHashing() async throws {
        // Mirrors Python's non-blocking lock: a second call while the
        // pipeline runs is a no-op.
        guard pipelineTask == nil else { return }
        pipelineGeneration += 1
        let generation = pipelineGeneration
        state.state = "hashing"
        state.scanned = 0
        state.error = nil
        pipelineTask = Task { await self.runPipeline(generation: generation) }
    }

    // MARK: - Hashing + clustering pipeline (port of scanner._run_hashing)

    private func runPipeline(generation: Int) async {
        defer {
            if pipelineGeneration == generation { pipelineTask = nil }
        }
        do {
            // Live clustering: rebuild groups periodically while hashing runs so
            // duplicates surface in the sidebar in real time instead of only at
            // the end. Metadata-based kinds (burst/RAW+JPEG/Live) appear almost
            // immediately; pHash groups fill in as hashes land.
            let liveClustering = Task { await self.runLiveClustering(generation: generation) }

            let hashInterval = signposter.beginInterval("hashing")
            do {
                try await hashPhotos(generation: generation)
            } catch {
                liveClustering.cancel()
                _ = await liveClustering.value
                throw error
            }
            signposter.endInterval("hashing", hashInterval)

            // Stop live clustering before the authoritative final pass so the two
            // don't overlap.
            liveClustering.cancel()
            _ = await liveClustering.value

            guard pipelineGeneration == generation else { return }
            state.state = "clustering"
            let clusterInterval = signposter.beginInterval("clustering")
            let clusterCount = try await store.write { db in
                try Clusterer.buildClusters(db)
            }
            signposter.endInterval("clustering", clusterInterval)

            guard pipelineGeneration == generation else { return }
            let captionInterval = signposter.beginInterval("captioning")
            await captionClusters(generation: generation)
            signposter.endInterval("captioning", captionInterval)

            guard pipelineGeneration == generation else { return }
            state.state = "done"
            print("[LocalBackend] Scan complete — \(clusterCount) clusters")
        } catch is CancellationError {
            // beginScan superseded this run; it already reset the state.
        } catch {
            guard pipelineGeneration == generation else { return }
            state.state = "error"
            state.error = error.localizedDescription
            print("[LocalBackend] Pipeline failed: \(error)")
        }
    }

    /// Periodically rebuilds clusters while hashing is in flight so the UI can
    /// show duplicates as they're discovered. Skips a rebuild when no new hashes
    /// have landed since the last one, and treats failures as non-fatal (the
    /// final clustering pass is authoritative). Runs until cancelled by
    /// `runPipeline` when hashing finishes.
    private func runLiveClustering(generation: Int) async {
        let interval = Duration.seconds(4)
        var lastScanned = -1
        while pipelineGeneration == generation && !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return   // cancelled
            }
            guard pipelineGeneration == generation, !Task.isCancelled else { return }
            guard state.scanned != lastScanned else { continue }
            lastScanned = state.scanned
            do {
                _ = try await store.write { db in try Clusterer.buildClusters(db) }
            } catch {
                print("[LocalBackend] Live clustering pass failed (non-fatal): \(error)")
            }
        }
    }

    /// Streaming pipeline: workers claim candidates one at a time from an
    /// actor-guarded cursor (no chunk barriers — one slow HEIC or cloud fetch
    /// never stalls finished workers), hash via PhotoKit-sourced thumbnails
    /// (`AssetHasher`), and results flush to the store in batched
    /// transactions of `writeBatchSize`.
    private func hashPhotos(generation: Int) async throws {
        let (candidates, total) = try await store.read { db -> ([HashCandidate], Int) in
            let rows = try Row.fetchAll(db, sql:
                "SELECT uuid, local_identifier FROM photos WHERE local_identifier IS NOT NULL"
            ).map { HashCandidate(uuid: $0["uuid"], localIdentifier: $0["local_identifier"]) }
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photos") ?? 0
            return (rows, total)
        }
        guard pipelineGeneration == generation else { return }
        state.totalPhotos = total
        state.skippedCloud = 0
        candidateCursor = 0
        candidateTotal = candidates.count
        pendingHashWrites = []
        pipelineFailure = nil

        let hasher = AssetHasher(
            uuidToIdentifier: candidates.map { ($0.uuid, $0.localIdentifier) })

        let workerCount = max(2, ProcessInfo.processInfo.activeProcessorCount)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    await self.runHashWorker(
                        candidates: candidates, hasher: hasher, generation: generation)
                }
            }
        }

        await flushHashWrites()
        if let failure = pipelineFailure { throw failure }
        try Task.checkCancellation()
    }

    /// nonisolated so hashing math runs on the global concurrent executor;
    /// the actor is only touched for cursor claims and result recording.
    private nonisolated func runHashWorker(
        candidates: [HashCandidate], hasher: AssetHasher, generation: Int
    ) async {
        while !Task.isCancelled,
              let index = await claimNextCandidateIndex(generation: generation) {
            let result = await hasher.hash(uuid: candidates[index].uuid)
            await record(result, generation: generation)
        }
    }

    private func claimNextCandidateIndex(generation: Int) -> Int? {
        guard pipelineGeneration == generation,
              pipelineFailure == nil,
              candidateCursor < candidateTotal
        else { return nil }
        defer { candidateCursor += 1 }
        return candidateCursor
    }

    private func record(_ result: AssetHasher.HashResult, generation: Int) async {
        guard pipelineGeneration == generation else { return }
        state.scanned += 1
        if let primary = result.primary {
            pendingHashWrites.append(
                (result.uuid, primary, result.variants.joined(separator: ",")))
            if pendingHashWrites.count >= Self.writeBatchSize {
                await flushHashWrites()
            }
        } else {
            state.skippedCloud += 1   // couldn't produce a hash for this asset
        }
        if state.scanned % 500 == 0, let start = state.scanStartTime {
            let elapsed = Date().timeIntervalSince1970 - start
            let rate = elapsed > 0 ? Double(state.scanned) / elapsed : 0
            print("[LocalBackend] Hashed \(state.scanned)/\(candidateTotal) — \(String(format: "%.1f", rate)) assets/s")
            signposter.emitEvent("hash-progress")
        }
    }

    private func flushHashWrites() async {
        guard !pendingHashWrites.isEmpty else { return }
        let batch = pendingHashWrites
        pendingHashWrites = []
        do {
            try await store.write { db in
                for item in batch {
                    try db.execute(
                        sql: "UPDATE photos SET phash=?, phash_variants=? WHERE uuid=?",
                        arguments: [item.primary, item.variants, item.uuid])
                }
            }
        } catch {
            pipelineFailure = error
        }
    }

    // MARK: - Captioning (Vision scene classification)

    /// Labels each freshly-built cluster with a short 2–3 word Vision
    /// classification of its representative photo (e.g. "Beach, Sky"). Runs in
    /// bounded-concurrency chunks so image loading + classification overlap
    /// without loading every representative into memory at once. Only clusters
    /// whose caption is still NULL are processed, so re-runs are cheap.
    private func captionClusters(generation: Int) async {
        let targets: [(id: Int, identifier: String)]
        do {
            targets = try await store.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT c.id AS id,
                           (SELECT p.local_identifier
                              FROM photos p
                              JOIN cluster_members cm ON cm.photo_uuid = p.uuid
                             WHERE cm.cluster_id = c.id AND p.local_identifier IS NOT NULL
                             ORDER BY p.uuid
                             LIMIT 1) AS identifier
                    FROM clusters c
                    WHERE c.caption IS NULL
                    """).compactMap { row in
                        guard let identifier: String = row["identifier"] else { return nil }
                        return (id: row["id"] as Int, identifier: identifier)
                    }
            }
        } catch {
            print("[LocalBackend] Caption query failed: \(error)")
            return
        }
        guard !targets.isEmpty else { return }

        let chunkSize = 6
        var index = 0
        while index < targets.count {
            guard pipelineGeneration == generation else { return }
            let chunk = Array(targets[index..<min(index + chunkSize, targets.count)])
            index += chunkSize

            let results = await withTaskGroup(of: (Int, String?).self) { group in
                for target in chunk {
                    group.addTask { (target.id, await Self.caption(for: target.identifier)) }
                }
                var acc: [(Int, String)] = []
                for await (id, caption) in group {
                    if let caption { acc.append((id, caption)) }
                }
                return acc
            }

            guard !results.isEmpty, pipelineGeneration == generation else { continue }
            try? await store.write { db in
                for (id, caption) in results {
                    try db.execute(
                        sql: "UPDATE clusters SET caption=? WHERE id=?",
                        arguments: [caption, id])
                }
            }
        }
    }

    /// Loads the representative image and returns its short scene label. Static
    /// (nonisolated) so image decode + Vision run off the actor.
    private static func caption(for localIdentifier: String) async -> String? {
        guard let cgImage = await loadCGImage(localIdentifier: localIdentifier) else { return nil }
        return ImageClassifier.label(for: cgImage)
    }

    /// PHAsset localIdentifier → downscaled CGImage suitable for classification.
    private static func loadCGImage(localIdentifier: String, maxDimension: CGFloat = 300) async -> CGImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            guard let asset = assets.firstObject else {
                continuation.resume(returning: nil); return
            }
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat   // single callback, no degraded pass
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            options.resizeMode = .fast
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: maxDimension, height: maxDimension),
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                guard let image else { continuation.resume(returning: nil); return }
                var rect = CGRect(origin: .zero, size: image.size)
                continuation.resume(returning: image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            }
        }
    }

    func status() async throws -> ScanStatus {
        let (photoCount, clusterCount) = try await store.read { db -> (Int, Int) in
            let photoCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photos") ?? 0
            let clusterCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clusters") ?? 0
            return (photoCount, clusterCount)
        }

        var displayState = state.state
        switch displayState {
        case "ingesting", "hashing", "clustering": displayState = "running"
        default: break
        }
        if displayState == "idle" && clusterCount > 0 {
            displayState = "done"
        }

        let elapsed: Double?
        if let start = state.scanStartTime, ["running", "done", "error"].contains(displayState) {
            elapsed = Date().timeIntervalSince1970 - start
        } else {
            elapsed = nil
        }

        var scanned = state.scanned
        if displayState == "done" && scanned == 0 {
            scanned = photoCount
        }

        return ScanStatus(
            state: displayState,
            totalPhotos: state.totalPhotos > 0 ? state.totalPhotos : photoCount,
            scanned: scanned,
            skippedCloud: state.skippedCloud,
            clustersFound: clusterCount,
            error: state.error,
            elapsedSeconds: elapsed
        )
    }

    func clusters(page: Int = 1, kind: String? = nil, sort: ClusterSort = .duplicates) async throws -> [ClusterSummary] {
        let pageSize = 50
        let offset = (page - 1) * pageSize
        return try await store.read { db in
            var sql = """
                SELECT c.id, c.kind, c.confidence, c.caption,
                       COUNT(cm.photo_uuid) as member_count,
                       MIN(cm.photo_uuid)   as representative_uuid,
                       MAX(p.date_taken)    as latest_date,
                       (SELECT p2.local_identifier
                          FROM photos p2
                          JOIN cluster_members cm2 ON cm2.photo_uuid = p2.uuid
                         WHERE cm2.cluster_id = c.id
                         ORDER BY p2.uuid
                         LIMIT 1)          as representative_identifier
                FROM clusters c
                JOIN cluster_members cm ON cm.cluster_id = c.id
                JOIN photos p ON p.uuid = cm.photo_uuid
                WHERE 1=1
                """
            var arguments: [DatabaseValueConvertible?] = []
            if let kind {
                sql += " AND c.kind = ?"
                arguments.append(kind)
            }
            let orderClause: String
            switch sort {
            case .duplicates: orderClause = "member_count DESC, c.confidence DESC"
            case .date:       orderClause = "latest_date DESC, member_count DESC"
            }
            sql += """

                GROUP BY c.id
                ORDER BY \(orderClause)
                LIMIT ? OFFSET ?
                """
            arguments.append(pageSize)
            arguments.append(offset)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return rows.map { row in
                ClusterSummary(
                    id: row["id"],
                    kind: row["kind"],
                    confidence: row["confidence"],
                    memberCount: row["member_count"],
                    representativeUuid: row["representative_uuid"],
                    representativeIdentifier: row["representative_identifier"],
                    caption: row["caption"]
                )
            }
        }
    }

    func cluster(id: Int) async throws -> ClusterDetail {
        try await store.read { db in
            guard let clusterRow = try Row.fetchOne(
                db, sql: "SELECT id, kind, confidence FROM clusters WHERE id = ?", arguments: [id]
            ) else {
                throw LocalBackendError.clusterNotFound(id)
            }

            let photoRows = try PhotoRow.fetchAll(db, sql: """
                SELECT p.* FROM photos p
                JOIN cluster_members cm ON cm.photo_uuid = p.uuid
                WHERE cm.cluster_id = ?
                ORDER BY p.date_taken ASC
                """, arguments: [id])

            let photos = photoRows.map { row in
                PhotoMeta(
                    uuid: row.uuid,
                    localIdentifier: row.localIdentifier,
                    filename: row.filename,
                    originalFilename: row.originalFilename,
                    dateTaken: row.dateTaken,
                    burstUuid: row.burstUuid,
                    isRaw: row.isRaw,
                    isLive: row.isLive,
                    width: row.width,
                    height: row.height,
                    isLocal: row.isLocal,
                    filePath: row.filePath,
                    phash: row.phash
                )
            }

            return ClusterDetail(
                id: clusterRow["id"],
                kind: clusterRow["kind"],
                confidence: clusterRow["confidence"],
                photos: photos
            )
        }
    }
}
