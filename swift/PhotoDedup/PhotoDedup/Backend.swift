import Foundation

/// The seam between the app and any scanning/hashing/clustering implementation.
/// `RemoteBackend` talks to the Python FastAPI server; a future `LocalBackend`
/// will run everything natively in Swift. Both must look identical to callers.
protocol Backend: Sendable {
    func beginScan() async throws
    func ingestBatch(_ records: [PhotoRecord]) async throws
    func updateFilePath(uuid: String, path: String) async throws
    func startHashing() async throws

    func status() async throws -> ScanStatus
    func clusters(page: Int, kind: String?) async throws -> [ClusterSummary]
    func cluster(id: Int) async throws -> ClusterDetail
}

extension Backend {
    func clusters(page: Int = 1) async throws -> [ClusterSummary] {
        try await clusters(page: page, kind: nil)
    }
}

/// Single dependency-injection point. Views call `CurrentBackend.shared` so we
/// can flip implementations from one place once `LocalBackend` lands.
enum CurrentBackend {
    static var shared: any Backend { RemoteBackend.shared }
}
