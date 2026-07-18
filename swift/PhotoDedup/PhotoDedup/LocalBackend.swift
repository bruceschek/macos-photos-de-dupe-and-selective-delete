import Foundation
import GRDB

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
    let path: String
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
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

    func updateFilePath(uuid: String, path: String) async throws {
        try await store.write { db in
            try db.execute(
                sql: "UPDATE photos SET file_path=?, is_local=1 WHERE uuid=?",
                arguments: [path, uuid])
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
            try await hashPhotos(generation: generation)
            guard pipelineGeneration == generation else { return }
            state.state = "clustering"
            let clusterCount = try await store.write { db in
                try Clusterer.buildClusters(db)
            }
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

    private func hashPhotos(generation: Int) async throws {
        let (imageRows, videoRows, total, skipped) = try await store.read {
            db -> ([HashCandidate], [HashCandidate], Int, Int) in
            let images = try Row.fetchAll(db, sql: """
                SELECT uuid, file_path FROM photos
                WHERE file_path IS NOT NULL AND is_local = 1 AND media_type = 'image'
                """).map { HashCandidate(uuid: $0["uuid"], path: $0["file_path"]) }
            let videos = try Row.fetchAll(db, sql: """
                SELECT uuid, file_path FROM photos
                WHERE file_path IS NOT NULL AND is_local = 1 AND media_type = 'video'
                """).map { HashCandidate(uuid: $0["uuid"], path: $0["file_path"]) }
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photos") ?? 0
            let skipped = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM photos WHERE is_local = 0 OR file_path IS NULL") ?? 0
            return (images, videos, total, skipped)
        }
        guard pipelineGeneration == generation else { return }
        state.totalPhotos = total
        state.skippedCloud = skipped

        var scanned = 0
        for chunk in imageRows.chunked(into: 32) {
            try Task.checkCancellation()
            try await writeHashes(computedFor: chunk, video: false)
            scanned += chunk.count
            guard pipelineGeneration == generation else { return }
            state.scanned = scanned
        }
        for chunk in videoRows.chunked(into: 8) {
            try Task.checkCancellation()
            try await writeHashes(computedFor: chunk, video: true)
            scanned += chunk.count
            guard pipelineGeneration == generation else { return }
            state.scanned = scanned
        }
    }

    private func writeHashes(computedFor chunk: [HashCandidate], video: Bool) async throws {
        let results = await Self.computeHashes(chunk, video: video)
        guard !results.isEmpty else { return }
        try await store.write { db in
            for (uuid, hash) in results {
                try db.execute(sql: "UPDATE photos SET phash=? WHERE uuid=?",
                               arguments: [hash, uuid])
            }
        }
    }

    /// nonisolated so the task-group children run on the global concurrent
    /// executor instead of serializing on this actor.
    private nonisolated static func computeHashes(
        _ chunk: [HashCandidate], video: Bool
    ) async -> [(String, String)] {
        await withTaskGroup(of: (String, String?).self) { group in
            for candidate in chunk {
                group.addTask {
                    if video {
                        return (candidate.uuid, await PHash.hash(videoAt: candidate.path))
                    }
                    return (candidate.uuid, PHash.hash(imageAt: candidate.path))
                }
            }
            var results: [(String, String)] = []
            for await (uuid, hash) in group {
                if let hash { results.append((uuid, hash)) }
            }
            return results
        }
    }

    func status() async throws -> ScanStatus {
        let (photoCount, clusterCount, skippedCount) = try await store.read { db -> (Int, Int, Int) in
            let photoCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photos") ?? 0
            let clusterCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clusters") ?? 0
            let skippedCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM photos WHERE is_local = 0 OR file_path IS NULL") ?? 0
            return (photoCount, clusterCount, skippedCount)
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
            skippedCloud: state.skippedCloud > 0 ? state.skippedCloud : skippedCount,
            clustersFound: clusterCount,
            error: state.error,
            elapsedSeconds: elapsed
        )
    }

    func clusters(page: Int = 1, kind: String? = nil) async throws -> [ClusterSummary] {
        let pageSize = 50
        let offset = (page - 1) * pageSize
        return try await store.read { db in
            var sql = """
                SELECT c.id, c.kind, c.confidence,
                       COUNT(cm.photo_uuid) as member_count,
                       MIN(cm.photo_uuid)   as representative_uuid
                FROM clusters c
                JOIN cluster_members cm ON cm.cluster_id = c.id
                WHERE 1=1
                """
            var arguments: [DatabaseValueConvertible?] = []
            if let kind {
                sql += " AND c.kind = ?"
                arguments.append(kind)
            }
            sql += """

                GROUP BY c.id
                ORDER BY c.confidence DESC, member_count DESC
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
                    representativeUuid: row["representative_uuid"]
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
