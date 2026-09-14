import Foundation
import CryptoKit

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

actor APIClient {
    private let baseURL: URL
    private let session: URLSession

    init() {
        let configured = Bundle.main.object(forInfoDictionaryKey: "APIBaseURL") as? String
        baseURL = URL(string: configured ?? "http://localhost:3100")!
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
    }

    func health() async throws {
        let _: HealthResponse = try await request("/api/health")
    }

    func signUp(name: String, email: String, password: String) async throws {
        let body = ["name": name, "email": email, "password": password]
        let _: AuthResponse = try await request("/api/auth/sign-up/email", method: "POST", body: body)
    }

    func signIn(email: String, password: String) async throws {
        let body = ["email": email, "password": password]
        let _: AuthResponse = try await request("/api/auth/sign-in/email", method: "POST", body: body)
    }

    func listOrganizations() async throws -> [OrganizationResponse] {
        try await request("/api/auth/organization/list")
    }

    func createOrganization(name: String) async throws -> OrganizationResponse {
        let slug = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-")) + "-" + String(UUID().uuidString.prefix(6)).lowercased()
        return try await request("/api/auth/organization/create", method: "POST", body: ["name": name, "slug": slug])
    }

    func push(organizationID: String, deviceID: UUID, mutations: [SyncMutation]) async throws -> PushResponse {
        try await request("/api/sync/push", method: "POST", body: PushBody(organizationId: organizationID, deviceId: deviceID, mutations: mutations))
    }

    func pull(organizationID: String, cursor: String) async throws -> PullResponse {
        let encoded = organizationID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? organizationID
        return try await request("/api/sync/pull?organizationId=\(encoded)&cursor=\(cursor)&limit=200")
    }

    func uploadVideo(
        organizationID: String,
        mediaID: UUID,
        fileURL: URL,
        revision: String? = nil,
        progress: @escaping @MainActor @Sendable (Int64) -> Void,
        shouldContinue: @escaping @MainActor @Sendable () -> Bool
    ) async throws -> Int64 {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize > 0 else { throw APIError(message: "Recording file is empty or missing.") }
        let upload: UploadSession = try await request("/api/uploads", method: "POST", body: StartUploadBody(
            organizationId: organizationID,
            mediaId: mediaID,
            fileName: revision.map { "\(mediaID)-\($0).\(fileURL.pathExtension)" } ?? fileURL.lastPathComponent,
            contentType: fileURL.pathExtension.lowercased() == "mp4" ? "video/mp4" : "video/quicktime",
            totalBytes: fileSize
        ))
        if upload.status == "complete" { return Int64(fileSize) }

        let received = Set(upload.receivedParts)
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var uploaded = Int64(0)
        for part in 1...upload.totalParts {
            guard await shouldContinue() else { throw APIError(message: "Upload paused while recording.") }
            let offset = UInt64((part - 1) * upload.chunkSize)
            let byteCount = min(upload.chunkSize, fileSize - Int(offset))
            if received.contains(part) {
                uploaded += Int64(byteCount)
                await progress(uploaded)
                continue
            }
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: byteCount), !data.isEmpty else { throw APIError(message: "Could not read recording part \(part).") }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try await uploadPart(uploadID: upload.uploadId, part: part, data: data, checksum: digest)
            uploaded += Int64(data.count)
            await progress(uploaded)
        }
        let _: CompleteUploadResponse = try await request("/api/uploads/\(upload.uploadId.uuidString)/complete", method: "POST", body: EmptyBody())
        return uploaded
    }

    func createShare(organizationID: String, mediaID: UUID) async throws -> URL {
        let share: ShareResponse = try await request("/api/shares", method: "POST", body: ShareBody(organizationId: organizationID, mediaId: mediaID))
        guard let url = URL(string: share.url) else { throw APIError(message: "Server returned an invalid share URL.") }
        return url
    }

    private func uploadPart(uploadID: UUID, part: Int, data: Data, checksum: String) async throws {
        var value = URLRequest(url: baseURL.appending(path: "/api/uploads/\(uploadID.uuidString)/parts/\(part)"))
        value.httpMethod = "PUT"
        value.httpBody = data
        value.timeoutInterval = 120
        value.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        value.setValue(checksum, forHTTPHeaderField: "x-chunk-sha256")
        value.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        for attempt in 1...3 {
            do {
                let (_, response) = try await session.data(for: value)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if (200..<300).contains(http.statusCode) { return }
                if http.statusCode < 500 { throw APIError(message: "Could not upload recording part \(part) (HTTP \(http.statusCode)).") }
                throw URLError(.badServerResponse)
            } catch let error as APIError {
                throw error
            } catch {
                guard attempt < 3 else { break }
                try await Task.sleep(for: .seconds(attempt))
            }
        }
        throw APIError(message: "Upload paused. It will resume when the server is reachable.")
    }

    private func request<Response: Decodable, Body: Encodable>(
        _ path: String,
        method: String = "GET",
        body: Body? = Optional<String>.none
    ) async throws -> Response {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError(message: "Invalid server response") }
            guard (200..<300).contains(http.statusCode) else {
                let server = try? JSONDecoder().decode(ServerError.self, from: data)
                throw APIError(message: server?.message ?? "Server returned HTTP \(http.statusCode)")
            }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError(message: "Cannot reach \(baseURL.host ?? "server"). Check Wi-Fi and local-network permission.")
        }
    }
}

private struct HealthResponse: Decodable { let status: String }
private struct AuthResponse: Decodable { let token: String? }
private struct ServerError: Decodable { let message: String? }
struct OrganizationResponse: Decodable { let id: String; let name: String }
struct PushBody: Encodable { let organizationId: String; let deviceId: UUID; let mutations: [SyncMutation] }
struct SyncMutation: Encodable {
    let mutationId: UUID
    let entityId: UUID
    let entityType: String
    let operation: String
    let baseVersion: Int?
    let parentId: UUID?
    let payload: [String: String]
    let clientTimestamp: String

    init(mutationId: UUID, entityId: UUID, entityType: String, operation: String = "upsert", baseVersion: Int?, parentId: UUID?, payload: [String: String], clientTimestamp: String) {
        self.mutationId = mutationId; self.entityId = entityId; self.entityType = entityType; self.operation = operation
        self.baseVersion = baseVersion; self.parentId = parentId; self.payload = payload; self.clientTimestamp = clientTimestamp
    }
}
struct PushResponse: Decodable { let results: [MutationResult] }
struct MutationResult: Decodable {
    let mutationId: UUID
    let status: String
    let version: Int?
    let serverVersion: Int?
}
struct PullResponse: Decodable { let changes: [RemoteChange]; let cursor: String; let hasMore: Bool }
struct RemoteChange: Decodable {
    let entityType: String
    let entityId: UUID
    let version: Int
    let operation: String
    let parentId: UUID?
    let payload: [String: String]
}
private struct StartUploadBody: Encodable { let organizationId: String; let mediaId: UUID; let fileName: String; let contentType: String; let totalBytes: Int }
private struct UploadSession: Decodable { let uploadId: UUID; let chunkSize: Int; let totalParts: Int; let receivedParts: [Int]; let status: String }
private struct EmptyBody: Encodable {}
private struct CompleteUploadResponse: Decodable { let mediaId: UUID; let status: String }
private struct ShareBody: Encodable { let organizationId: String; let mediaId: UUID }
private struct ShareResponse: Decodable { let token: String; let url: String }
