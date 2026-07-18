import Foundation
import GRDB

/// Native port of the clustering passes in `python/ml/scanner.py`
/// (`_build_clusters` and friends). Same five cluster kinds and the same
/// thresholds, so results match the Python backend's on identical inputs.
enum Clusterer {
    static let phashThreshold = 4
    private static let phashMinBits = 4
    private static let phashMaxBits = 60

    // iOS names edited photos "FullSizeRender" etc. — matching on those stems
    // collapses unrelated photos into one giant cluster.
    private static let genericStems: Set<String> = ["fullsizerender", "img_e"]

    // RAW+JPEG from the same shot are captured simultaneously; 120 s allows
    // clock drift while rejecting recycled sequential names (IMG_0544 …).
    private static let rawJpegMaxGapSeconds = 120.0

    // Real duplicate videos are recorded within seconds of each other.
    private static let videoMaxGapSeconds = 120.0
    private static let videoDurationToleranceSeconds = 1.0
    // Looser than the photo threshold — frame extraction is noisier.
    private static let videoPhashThreshold = 10
    // 1.20 lets 5:4 vs 4:3 pass; landscape vs portrait fails immediately.
    private static let videoAspectRatioMaxRatio = 1.20

    /// Rebuilds all clusters from scratch. Returns the cluster count.
    static func buildClusters(_ db: Database) throws -> Int {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: "DELETE FROM cluster_members")
        try db.execute(sql: "DELETE FROM clusters")

        try clusterBursts(db, now: now)
        try clusterRawJpeg(db, now: now)
        try clusterLivePhotos(db, now: now)
        try clusterPhash(db, now: now)
        try clusterVideos(db, now: now)

        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clusters") ?? 0
    }

    // MARK: - Cluster kinds

    private static func clusterBursts(_ db: Database, now: Double) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT burst_uuid, GROUP_CONCAT(uuid) as uuids
            FROM photos WHERE burst_uuid IS NOT NULL
            GROUP BY burst_uuid HAVING COUNT(*) > 1
            """)
        for row in rows {
            let joined: String = row["uuids"]
            try insertCluster(db, kind: "burst", confidence: 1.0, now: now,
                              members: joined.components(separatedBy: ","))
        }
    }

    private struct StemEntry {
        let uuid: String
        let isRaw: Bool
        let dateTaken: Double
    }

    private static func clusterRawJpeg(_ db: Database, now: Double) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT uuid, original_filename, is_raw, date_taken FROM photos
            WHERE is_raw = 1
               OR lower(original_filename) LIKE '%.jpg'
               OR lower(original_filename) LIKE '%.jpeg'
            """)

        var stems: [String: [StemEntry]] = [:]
        for row in rows {
            guard let filename: String = row["original_filename"] else { continue }
            let stem = (filename as NSString).deletingPathExtension.lowercased()
            if genericStems.contains(stem) { continue }
            stems[stem, default: []].append(StemEntry(
                uuid: row["uuid"],
                isRaw: row["is_raw"],
                dateTaken: row["date_taken"] ?? 0))
        }

        for entries in stems.values where entries.count >= 2 {
            // Sub-group by capture time — sequential camera counters reset
            // across trips, so one stem can cover unrelated photos.
            let sorted = entries.sorted { $0.dateTaken < $1.dateTaken }
            for group in timeGroups(sorted, maxGap: rawJpegMaxGapSeconds, date: \.dateTaken) {
                guard group.count >= 2,
                      group.contains(where: \.isRaw),
                      group.contains(where: { !$0.isRaw })
                else { continue }
                try insertCluster(db, kind: "raw_jpeg", confidence: 1.0, now: now,
                                  members: group.map(\.uuid))
            }
        }
    }

    private static func clusterLivePhotos(_ db: Database, now: Double) throws {
        // Only cluster by burst_uuid — filename-stem matching is too broad
        // (see genericStems note above).
        let rows = try Row.fetchAll(db, sql:
            "SELECT uuid, burst_uuid FROM photos WHERE is_live = 1 AND burst_uuid IS NOT NULL")
        var groups: [String: [String]] = [:]
        for row in rows {
            groups[row["burst_uuid"], default: []].append(row["uuid"])
        }
        for uuids in groups.values where uuids.count > 1 {
            try insertCluster(db, kind: "live", confidence: 1.0, now: now, members: uuids)
        }
    }

    private static func clusterPhash(_ db: Database, now: Double) throws {
        let rows = try Row.fetchAll(db, sql:
            "SELECT uuid, phash FROM photos WHERE phash IS NOT NULL")

        var hashes: [(uuid: String, value: UInt64)] = []
        for row in rows {
            let hex: String = row["phash"]
            guard let value = UInt64(hex, radix: 16) else { continue }
            // Near-uniform frames (all-black clips, blank scans) produce
            // degenerate hashes that would glue everything together.
            let bitCount = value.nonzeroBitCount
            if bitCount <= phashMinBits || bitCount >= phashMaxBits { continue }
            hashes.append((row["uuid"], value))
        }
        guard !hashes.isEmpty else { return }

        var unionFind = UnionFind()
        let tree = BKTree()
        for (uuid, value) in hashes {
            unionFind.add(uuid)
            for neighbor in tree.find(value, within: phashThreshold) {
                unionFind.union(uuid, neighbor)
            }
            tree.add(value, uuid: uuid)
        }

        var groups: [String: [String]] = [:]
        for (uuid, _) in hashes {
            groups[unionFind.find(uuid), default: []].append(uuid)
        }
        let confidence = max(0.0, 1.0 - Double(phashThreshold) / 64.0)
        for group in groups.values where group.count > 1 {
            try insertCluster(db, kind: "phash", confidence: confidence, now: now, members: group)
        }
    }

    private struct VideoEntry {
        let uuid: String
        let duration: Double
        let dateTaken: Double
        let phash: String?
        let width: Int
        let height: Int
    }

    /// Four-level funnel: same filename stem → capture-time proximity →
    /// duration proximity + aspect-ratio sanity → frame-pHash visual veto.
    private static func clusterVideos(_ db: Database, now: Double) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT uuid, original_filename, duration, date_taken, phash, width, height
            FROM photos WHERE media_type = 'video'
            """)

        var stems: [String: [VideoEntry]] = [:]
        for row in rows {
            guard let filename: String = row["original_filename"] else { continue }
            let stem = (filename as NSString).deletingPathExtension.lowercased()
            guard !stem.isEmpty else { continue }
            stems[stem, default: []].append(VideoEntry(
                uuid: row["uuid"],
                duration: row["duration"] ?? 0,
                dateTaken: row["date_taken"] ?? 0,
                phash: row["phash"],
                width: row["width"] ?? 0,
                height: row["height"] ?? 0))
        }

        for entries in stems.values where entries.count >= 2 {
            let sorted = entries.sorted { $0.dateTaken < $1.dateTaken }
            for timeGroup in timeGroups(sorted, maxGap: videoMaxGapSeconds, date: \.dateTaken) {
                guard timeGroup.count >= 2 else { continue }

                var durationGroups: [[VideoEntry]] = []
                for entry in timeGroup {
                    var placed = false
                    for index in durationGroups.indices
                    where abs(durationGroups[index][0].duration - entry.duration) <= videoDurationToleranceSeconds {
                        durationGroups[index].append(entry)
                        placed = true
                        break
                    }
                    if !placed { durationGroups.append([entry]) }
                }

                for group in durationGroups {
                    guard group.count >= 2 else { continue }

                    // Portrait vs landscape, or clearly different crops, are
                    // different clips even with matching names and durations.
                    let dimensioned = group.filter { $0.width > 0 && $0.height > 0 }
                    if dimensioned.count == group.count {
                        let ratios = dimensioned.map { Double($0.width) / Double($0.height) }
                        if let minRatio = ratios.min(), let maxRatio = ratios.max(),
                           minRatio > 0, maxRatio / minRatio > videoAspectRatioMaxRatio {
                            continue
                        }
                    }

                    // Frame-pHash veto: when EVERY member has a hash, all pairs
                    // must be visually similar; one mismatch disqualifies.
                    let parsed = group.compactMap { $0.phash.flatMap { UInt64($0, radix: 16) } }
                    if parsed.count == group.count,
                       !allPairsWithin(parsed, threshold: videoPhashThreshold) {
                        continue
                    }

                    try insertCluster(db, kind: "video", confidence: 1.0, now: now,
                                      members: group.map(\.uuid))
                }
            }
        }
    }

    // MARK: - Helpers

    private static func insertCluster(
        _ db: Database, kind: String, confidence: Double, now: Double, members: [String]
    ) throws {
        try db.execute(
            sql: "INSERT INTO clusters (kind, confidence, created_at) VALUES (?, ?, ?)",
            arguments: [kind, confidence, now])
        let clusterId = db.lastInsertedRowID
        for uuid in members {
            try db.execute(sql: "INSERT INTO cluster_members VALUES (?, ?)",
                           arguments: [clusterId, uuid])
        }
    }

    /// First-fit grouping by proximity to each group's first (anchor) element,
    /// matching the Python loops exactly. Input must be sorted by date.
    private static func timeGroups<T>(_ entries: [T], maxGap: Double, date: KeyPath<T, Double>) -> [[T]] {
        var groups: [[T]] = []
        for entry in entries {
            var placed = false
            for index in groups.indices
            where abs(entry[keyPath: date] - groups[index][0][keyPath: date]) <= maxGap {
                groups[index].append(entry)
                placed = true
                break
            }
            if !placed { groups.append([entry]) }
        }
        return groups
    }

    private static func allPairsWithin(_ values: [UInt64], threshold: Int) -> Bool {
        for i in values.indices {
            for j in values.indices where j > i {
                if PHash.hammingDistance(values[i], values[j]) > threshold { return false }
            }
        }
        return true
    }
}

/// Union-find over photo UUIDs with path compression (port of the closures
/// inside `_cluster_phash`).
struct UnionFind {
    private var parent: [String: String] = [:]

    mutating func add(_ element: String) {
        if parent[element] == nil { parent[element] = element }
    }

    mutating func find(_ element: String) -> String {
        var root = element
        while let next = parent[root], next != root { root = next }
        var current = element
        while let next = parent[current], next != root {
            parent[current] = root
            current = next
        }
        return root
    }

    mutating func union(_ a: String, _ b: String) {
        let rootA = find(a)
        let rootB = find(b)
        if rootA != rootB { parent[rootB] = rootA }
    }
}

/// Metric tree for pHash Hamming-distance neighbor lookups (port of `_BKTree`).
final class BKTree {
    private final class Node {
        let hash: UInt64
        var uuids: [String]
        var children: [Int: Node] = [:]
        init(hash: UInt64, uuid: String) {
            self.hash = hash
            self.uuids = [uuid]
        }
    }

    private var root: Node?

    func add(_ hash: UInt64, uuid: String) {
        guard let root else {
            self.root = Node(hash: hash, uuid: uuid)
            return
        }
        var node = root
        while true {
            let distance = PHash.hammingDistance(hash, node.hash)
            if distance == 0 {
                node.uuids.append(uuid)
                return
            }
            if let child = node.children[distance] {
                node = child
            } else {
                node.children[distance] = Node(hash: hash, uuid: uuid)
                return
            }
        }
    }

    func find(_ hash: UInt64, within threshold: Int) -> [String] {
        guard let root else { return [] }
        var matches: [String] = []
        var stack = [root]
        while let node = stack.popLast() {
            let distance = PHash.hammingDistance(hash, node.hash)
            if distance <= threshold {
                matches.append(contentsOf: node.uuids)
            }
            for (edge, child) in node.children
            where edge >= distance - threshold && edge <= distance + threshold {
                stack.append(child)
            }
        }
        return matches
    }
}
