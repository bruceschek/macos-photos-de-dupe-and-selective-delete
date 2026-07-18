import Foundation

enum APIError: Error, LocalizedError {
    case badStatus(Int)
    case serverUnreachable

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): "Server returned status \(code)"
        case .serverUnreachable: "Python backend is not running. Start it with: uv run python main.py"
        }
    }
}

struct RemoteBackend: Backend {
    static let shared = RemoteBackend()

    private let base = URL(string: "http://127.0.0.1:8765")!
    private let decoder = JSONDecoder()

    func status() async throws -> ScanStatus {
        try await get("/status")
    }

    func beginScan() async throws {
        try await post("scan/begin")
    }

    func ingestBatch(_ records: [PhotoRecord]) async throws {
        let url = base.appendingPathComponent("scan/ingest")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let encoder = JSONEncoder()
        req.httpBody = try encoder.encode(["records": records])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    func startHashing() async throws {
        try await post("scan/hash")
    }

    func updateFilePath(uuid: String, path: String) async throws {
        let url = base.appendingPathComponent("photos/\(uuid)/file-path")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["file_path": path])
        let (_, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func post(_ path: String) async throws {
        let url = base.appendingPathComponent(path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw APIError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? 0)
            }
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.serverUnreachable
        }
    }

    func clusters(page: Int = 1, kind: String? = nil) async throws -> [ClusterSummary] {
        var path = "/clusters?page=\(page)&page_size=50"
        if let kind { path += "&kind=\(kind)" }
        return try await get(path)
    }

    func cluster(id: Int) async throws -> ClusterDetail {
        try await get("/clusters/\(id)")
    }

    func thumbnailURL(uuid: String, size: Int = 400) -> URL {
        base.appendingPathComponent("photos/\(uuid)/thumbnail")
            .appending(queryItems: [URLQueryItem(name: "size", value: "\(size)")])
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let url = URL(string: path, relativeTo: base)!
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(from: url)
        } catch {
            throw APIError.serverUnreachable
        }
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.badStatus((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try decoder.decode(T.self, from: data)
    }
}
