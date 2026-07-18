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

/// Single dependency-injection point. Views call `CurrentBackend.shared`.
/// `useLocalBackend` defaults to `true` (registered in `PhotoDedupApp.init`):
/// the native backend covers the full scan → hash → cluster pipeline, so
/// Python is opt-in via Settings for anyone who wants the old path back.
enum CurrentBackend {
    static let useLocalBackendKey = "useLocalBackend"

    static var shared: any Backend {
        UserDefaults.standard.bool(forKey: useLocalBackendKey) ? LocalBackend.shared : RemoteBackend.shared
    }
}
