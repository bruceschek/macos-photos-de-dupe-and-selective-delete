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

    /// One candidate group, not yet written to the DB. Collecting all passes'
    /// output before touching `clusters` lets `buildClusters` diff against what
    /// is already there instead of blindly delete-and-reinsert.
    private struct ProposedCluster {
        let kind: String
        let confidence: Double
        let members: [String]
    }

    /// Rebuilds clusters, preserving the row (and id) of any cluster whose kind
    /// and exact member set didn't change since the last build. Live clustering
    /// runs this every few seconds while hashing is still in flight; without
    /// diffing, every pass would delete and recreate every cluster with a new
    /// autoincrement id, and the sidebar/detail selection would jump around
    /// under the user mid-scan even though most groups aren't actually
    /// changing. Returns the final cluster count.
    static func buildClusters(_ db: Database) throws -> Int {
        var proposed: [ProposedCluster] = []
        try clusterBursts(db, &proposed)
        try clusterRawJpeg(db, &proposed)
        try clusterLivePhotos(db, &proposed)
        try clusterPhash(db, &proposed)
        try clusterVideos(db, &proposed)

        let existing = try Row.fetchAll(db, sql: """
            SELECT c.id, c.kind, GROUP_CONCAT(cm.photo_uuid) as members
            FROM clusters c
            LEFT JOIN cluster_members cm ON cm.cluster_id = c.id
            GROUP BY c.id
            """)
        var existingIdBySignature: [String: Int64] = [:]
        for row in existing {
            let members: String? = row["members"]
            let sorted = (members ?? "").split(separator: ",").sorted().joined(separator: ",")
            existingIdBySignature["\(row["kind"] as String)|\(sorted)"] = row["id"]
        }

        let now = Date().timeIntervalSince1970
        var keptIds = Set<Int64>()
        for cluster in proposed {
            let sorted = cluster.members.sorted().joined(separator: ",")
            let signature = "\(cluster.kind)|\(sorted)"
            if let existingId = existingIdBySignature[signature] {
                keptIds.insert(existingId)   // unchanged — leave row (and caption) alone
            } else {
                try insertCluster(db, kind: cluster.kind, confidence: cluster.confidence,
                                  now: now, members: cluster.members)
            }
        }

        let staleIds = Set(existingIdBySignature.values).subtracting(keptIds)
        if !staleIds.isEmpty {
            try db.execute(
                sql: "DELETE FROM clusters WHERE id IN (\(staleIds.map(String.init).joined(separator: ",")))")
        }

        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clusters") ?? 0
    }

    // MARK: - Cluster kinds

    private static func clusterBursts(_ db: Database, _ proposed: inout [ProposedCluster]) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT burst_uuid, GROUP_CONCAT(uuid) as uuids
            FROM photos WHERE burst_uuid IS NOT NULL
            GROUP BY burst_uuid HAVING COUNT(*) > 1
            """)
        for row in rows {
            let joined: String = row["uuids"]
            proposed.append(ProposedCluster(kind: "burst", confidence: 1.0,
                              members: joined.components(separatedBy: ",")))
        }
    }

    private struct StemEntry {
        let uuid: String
        let isRaw: Bool
        let dateTaken: Double
    }

    private static func clusterRawJpeg(_ db: Database, _ proposed: inout [ProposedCluster]) throws {
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
                proposed.append(ProposedCluster(kind: "raw_jpeg", confidence: 1.0,
                                  members: group.map(\.uuid)))
            }
        }
    }

    private static func clusterLivePhotos(_ db: Database, _ proposed: inout [ProposedCluster]) throws {
        // Only cluster by burst_uuid — filename-stem matching is too broad
        // (see genericStems note above).
        let rows = try Row.fetchAll(db, sql:
            "SELECT uuid, burst_uuid FROM photos WHERE is_live = 1 AND burst_uuid IS NOT NULL")
        var groups: [String: [String]] = [:]
        for row in rows {
            groups[row["burst_uuid"], default: []].append(row["uuid"])
        }
        for uuids in groups.values where uuids.count > 1 {
            proposed.append(ProposedCluster(kind: "live", confidence: 1.0, members: uuids))
        }
    }

    private struct PhashEntry {
        let uuid: String
        let primary: UInt64
        let variants: [UInt64]
    }

    private static func clusterPhash(_ db: Database, _ proposed: inout [ProposedCluster]) throws {
        // Videos are excluded here: their sampled-frame hashes live in the same
        // hash space as photo hashes, but pooling the two lets a video's frame
        // (however visually unrelated) chain-match a still image by DCT
        // coincidence — most often with near-black or near-blank frames, which
        // are common in old digitized footage. Videos get their own funnel in
        // clusterVideos, gated on filename/time/duration, not just raw hash
        // proximity.
        let rows = try Row.fetchAll(db, sql: """
            SELECT uuid, phash, phash_variants FROM photos
            WHERE phash IS NOT NULL AND media_type != 'video'
            """)

        var entries: [PhashEntry] = []
        for row in rows {
            let hex: String = row["phash"]
            guard let primary = UInt64(hex, radix: 16) else { continue }
            // Near-uniform frames (all-black clips, blank scans) produce
            // degenerate hashes that would glue everything together.
            let bitCount = primary.nonzeroBitCount
            if bitCount <= phashMinBits || bitCount >= phashMaxBits { continue }
            let variants = parseVariants(row["phash_variants"], fallback: primary)
            entries.append(PhashEntry(uuid: row["uuid"], primary: primary, variants: variants))
        }
        guard !entries.isEmpty else { return }

        // Tree holds primary hashes; each photo queries with all its variants
        // (8 dihedral orientations), so a rotated or mirrored duplicate still
        // lands within the Hamming threshold. Union-find is only used here to
        // generate cheap *candidate* components from the BK-tree — membership
        // in a component means "connected by a chain of close pairs," not
        // "every member is close to every other member" (single-linkage), so
        // it's refined below before becoming real clusters.
        var unionFind = UnionFind()
        let tree = BKTree()
        for entry in entries {
            unionFind.add(entry.uuid)
            tree.add(entry.primary, uuid: entry.uuid)
        }
        for entry in entries {
            for variant in entry.variants {
                for neighbor in tree.find(variant, within: phashThreshold) {
                    unionFind.union(entry.uuid, neighbor)
                }
            }
        }

        var candidates: [String: [String]] = [:]
        for entry in entries {
            candidates[unionFind.find(entry.uuid), default: []].append(entry.uuid)
        }
        let entryByUuid = Dictionary(uniqueKeysWithValues: entries.map { ($0.uuid, $0) })
        let confidence = max(0.0, 1.0 - Double(phashThreshold) / 64.0)
        for candidate in candidates.values where candidate.count > 1 {
            for tight in tightSubgroups(candidate, entryByUuid: entryByUuid) where tight.count > 1 {
                proposed.append(ProposedCluster(kind: "phash", confidence: confidence, members: tight))
            }
        }
    }

    /// Union-find candidate components are single-linkage: A↔B↔C only implies
    /// A and C are each within one hop of a shared neighbor, not that A and C
    /// are similar to each other. That chaining is exactly how visually
    /// unrelated photos (each individually close to a shared low-detail
    /// neighbor — a mostly-blank scan, a high-contrast text card) end up
    /// welded into one "duplicate" group. This greedy pass splits each
    /// component into maximal subgroups where every member is within
    /// `phashThreshold` of every other member (complete-linkage), admitting
    /// new members only when they're close to everyone already accepted.
    private static func tightSubgroups(
        _ uuids: [String], entryByUuid: [String: PhashEntry]
    ) -> [[String]] {
        var unassigned = uuids
        var result: [[String]] = []
        while !unassigned.isEmpty {
            let seedUuid = unassigned.removeFirst()
            guard let seed = entryByUuid[seedUuid] else { continue }
            var subgroup = [seedUuid]
            var subgroupVariants = [seed.variants]
            var remaining: [String] = []
            for candidateUuid in unassigned {
                guard let candidate = entryByUuid[candidateUuid] else { continue }
                let fitsAll = subgroupVariants.allSatisfy {
                    minHammingDistance($0, candidate.variants) <= phashThreshold
                }
                if fitsAll {
                    subgroup.append(candidateUuid)
                    subgroupVariants.append(candidate.variants)
                } else {
                    remaining.append(candidateUuid)
                }
            }
            result.append(subgroup)
            unassigned = remaining
        }
        return result
    }

    private static func minHammingDistance(_ a: [UInt64], _ b: [UInt64]) -> Int {
        var best = Int.max
        for x in a {
            for y in b {
                best = min(best, PHash.hammingDistance(x, y))
            }
        }
        return best
    }

    private static func parseVariants(_ joined: String?, fallback: UInt64) -> [UInt64] {
        let parsed = joined?.split(separator: ",").compactMap { UInt64($0, radix: 16) } ?? []
        return parsed.isEmpty ? [fallback] : parsed
    }

    private struct VideoEntry {
        let uuid: String
        let duration: Double
        let dateTaken: Double
        let frameHashes: [UInt64]   // sampled frames (or poster); empty = no visual data
        let width: Int
        let height: Int
    }

    /// Four-level funnel: same filename stem → capture-time proximity →
    /// duration proximity + aspect-ratio sanity → frame-pHash visual veto.
    private static func clusterVideos(_ db: Database, _ proposed: inout [ProposedCluster]) throws {
        let rows = try Row.fetchAll(db, sql: """
            SELECT uuid, original_filename, duration, date_taken, phash, phash_variants, width, height
            FROM photos WHERE media_type = 'video'
            """)

        var stems: [String: [VideoEntry]] = [:]
        for row in rows {
            guard let filename: String = row["original_filename"] else { continue }
            let stem = (filename as NSString).deletingPathExtension.lowercased()
            guard !stem.isEmpty else { continue }
            let primaryHex: String? = row["phash"]
            let frameHashes: [UInt64]
            if let primary = primaryHex.flatMap({ UInt64($0, radix: 16) }) {
                frameHashes = parseVariants(row["phash_variants"], fallback: primary)
            } else {
                frameHashes = []
            }
            stems[stem, default: []].append(VideoEntry(
                uuid: row["uuid"],
                duration: row["duration"] ?? 0,
                dateTaken: row["date_taken"] ?? 0,
                frameHashes: frameHashes,
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

                    // Frame-pHash veto: when EVERY member has visual data, all
                    // pairs must be similar in at least one frame combination;
                    // one fully-mismatched pair disqualifies the group.
                    if group.allSatisfy({ !$0.frameHashes.isEmpty }),
                       !allPairsMinWithin(group.map(\.frameHashes), threshold: videoPhashThreshold) {
                        continue
                    }

                    proposed.append(ProposedCluster(kind: "video", confidence: 1.0,
                                      members: group.map(\.uuid)))
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

    /// True iff every pair of videos has at least one frame combination
    /// within the Hamming threshold (min cross-distance per pair).
    private static func allPairsMinWithin(_ hashLists: [[UInt64]], threshold: Int) -> Bool {
        for i in hashLists.indices {
            for j in hashLists.indices where j > i {
                var minDistance = Int.max
                for a in hashLists[i] {
                    for b in hashLists[j] {
                        minDistance = min(minDistance, PHash.hammingDistance(a, b))
                    }
                }
                if minDistance > threshold { return false }
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
