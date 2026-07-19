import Foundation
import GRDB

/// Row types mirror `python/ml/db.py` column-for-column so the two schemas
/// stay swappable. These are the on-disk shape; `Models.swift` types are the
/// wire/API shape used by both backends.

struct PhotoRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "photos"

    var uuid: String
    var localIdentifier: String?
    var filename: String
    var originalFilename: String?
    var dateTaken: Double?
    var burstUuid: String?
    var isRaw: Bool
    var isLive: Bool
    var width: Int?
    var height: Int?
    var isLocal: Bool
    var filePath: String?
    var mediaType: String
    var duration: Double?
    var phash: String?
    var scannedAt: Double?

    enum CodingKeys: String, CodingKey {
        case uuid, filename, width, height, duration, phash
        case localIdentifier = "local_identifier"
        case originalFilename = "original_filename"
        case dateTaken = "date_taken"
        case burstUuid = "burst_uuid"
        case isRaw = "is_raw"
        case isLive = "is_live"
        case isLocal = "is_local"
        case filePath = "file_path"
        case mediaType = "media_type"
        case scannedAt = "scanned_at"
    }
}

struct ClusterDBRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "clusters"

    var id: Int64?
    var kind: String
    var confidence: Double
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, kind, confidence
        case createdAt = "created_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

struct ClusterMemberRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "cluster_members"

    var clusterId: Int64
    var photoUuid: String

    enum CodingKeys: String, CodingKey {
        case clusterId = "cluster_id"
        case photoUuid = "photo_uuid"
    }
}

struct ScanStateRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "scan_state"

    var key: String
    var value: String?
}

/// GRDB-backed store at `~/Library/Application Support/PhotoDedup/photos.db`.
/// Schema mirrors `python/ml/db.py` exactly: same tables, columns, and indexes.
/// Separate database from the Python backend's `python/ml/photos.db` — no
/// data migration between them.
actor PhotoStore {
    static let shared = PhotoStore()

    private let dbQueue: DatabaseQueue

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoDedup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("photos.db")

        var config = Configuration()
        config.foreignKeysEnabled = true

        dbQueue = try! DatabaseQueue(path: dbURL.path, configuration: config)

        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS photos (
                    uuid        TEXT PRIMARY KEY,
                    local_identifier TEXT,
                    filename    TEXT NOT NULL,
                    original_filename TEXT,
                    date_taken  REAL,
                    burst_uuid  TEXT,
                    is_raw      INTEGER NOT NULL DEFAULT 0,
                    is_live     INTEGER NOT NULL DEFAULT 0,
                    width       INTEGER,
                    height      INTEGER,
                    is_local    INTEGER NOT NULL DEFAULT 1,
                    file_path   TEXT,
                    media_type  TEXT NOT NULL DEFAULT 'image',
                    duration    REAL,
                    phash       TEXT,
                    scanned_at  REAL
                );

                CREATE INDEX IF NOT EXISTS idx_photos_phash      ON photos(phash);
                CREATE INDEX IF NOT EXISTS idx_photos_burst_uuid ON photos(burst_uuid);
                CREATE INDEX IF NOT EXISTS idx_photos_filename   ON photos(original_filename);

                CREATE TABLE IF NOT EXISTS clusters (
                    id          INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind        TEXT NOT NULL,
                    confidence  REAL NOT NULL DEFAULT 1.0,
                    created_at  REAL NOT NULL
                );

                CREATE TABLE IF NOT EXISTS cluster_members (
                    cluster_id  INTEGER NOT NULL REFERENCES clusters(id) ON DELETE CASCADE,
                    photo_uuid  TEXT    NOT NULL REFERENCES photos(uuid) ON DELETE CASCADE,
                    PRIMARY KEY (cluster_id, photo_uuid)
                );

                CREATE INDEX IF NOT EXISTS idx_cm_cluster ON cluster_members(cluster_id);
                CREATE INDEX IF NOT EXISTS idx_cm_photo   ON cluster_members(photo_uuid);

                CREATE TABLE IF NOT EXISTS scan_state (
                    key   TEXT PRIMARY KEY,
                    value TEXT
                );
                """)
        }
        migrator.registerMigration("v2") { db in
            // Alternate hashes per photo: 8 dihedral orientations for images,
            // sampled frame hashes for videos. Comma-joined hex, primary first.
            try db.execute(sql: "ALTER TABLE photos ADD COLUMN phash_variants TEXT")
        }
        migrator.registerMigration("v3") { db in
            // Short 2–3 word Vision classification of the cluster's representative
            // photo (e.g. "Beach, Sky"). Populated during the clustering pass.
            try db.execute(sql: "ALTER TABLE clusters ADD COLUMN caption TEXT")
        }
        try! migrator.migrate(dbQueue)
    }

    func write<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await dbQueue.write(block)
    }

    func read<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await dbQueue.read(block)
    }
}
