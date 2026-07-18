import Foundation

struct PhotoMeta: Codable, Identifiable, Sendable {
    var id: String { uuid }
    let uuid: String
    let localIdentifier: String?
    let filename: String
    let originalFilename: String?
    let dateTaken: Double?
    let burstUuid: String?
    let isRaw: Bool
    let isLive: Bool
    let width: Int?
    let height: Int?
    let isLocal: Bool
    let filePath: String?
    let phash: String?

    enum CodingKeys: String, CodingKey {
        case uuid, filename
        case localIdentifier = "local_identifier"
        case originalFilename = "original_filename"
        case dateTaken = "date_taken"
        case burstUuid = "burst_uuid"
        case isRaw = "is_raw"
        case isLive = "is_live"
        case width, height
        case isLocal = "is_local"
        case filePath = "file_path"
        case phash
    }
}


struct ClusterSummary: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let kind: String
    let confidence: Double
    let memberCount: Int
    let representativeUuid: String

    enum CodingKeys: String, CodingKey {
        case id, kind, confidence
        case memberCount = "member_count"
        case representativeUuid = "representative_uuid"
    }
}

struct ClusterDetail: Codable, Identifiable, Sendable {
    let id: Int
    let kind: String
    let confidence: Double
    var photos: [PhotoMeta]   // var so the grid can remove items on lightbox delete
}

struct ScanStatus: Codable, Sendable {
    let state: String
    let totalPhotos: Int
    let scanned: Int
    let skippedCloud: Int
    let clustersFound: Int
    let error: String?
    let elapsedSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case state
        case totalPhotos = "total_photos"
        case scanned
        case skippedCloud = "skipped_cloud"
        case clustersFound = "clusters_found"
        case error
        case elapsedSeconds = "elapsed_seconds"
    }
}
