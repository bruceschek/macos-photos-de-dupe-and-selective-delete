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
    /// Best-known guess at whether the original is on this Mac. Exact for
    /// videos, optimistic for images — see `AssetHasher.HashResult.isLocal`.
    let isLocal: Bool
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
        case phash
    }
}


struct ClusterSummary: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let kind: String
    let confidence: Double
    let memberCount: Int
    let representativeUuid: String
    let representativeIdentifier: String?   // PHAsset localIdentifier for the row thumbnail
    let caption: String?                    // Vision 2–3 word scene label, nil until captioned
    let timeSpanSeconds: Double?            // study blocks only: capture duration of the run
    let estimatedRedundant: Int?            // study blocks only: rough cull count

    enum CodingKeys: String, CodingKey {
        case id, kind, confidence, caption
        case memberCount = "member_count"
        case representativeUuid = "representative_uuid"
        case representativeIdentifier = "representative_identifier"
        case timeSpanSeconds = "time_span_seconds"
        case estimatedRedundant = "estimated_redundant"
    }
}

enum ClusterSort: String, CaseIterable, Identifiable, Sendable {
    case duplicates   // most photos first (default)
    case date         // newest photo in the group first

    var id: String { rawValue }
    var label: String {
        switch self {
        case .duplicates: "Number of Duplicates"
        case .date: "Date"
        }
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
