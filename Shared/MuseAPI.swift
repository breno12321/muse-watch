import Foundation

public struct MuseVM: Sendable {
    public let id: String
    public let name: String
    public let token: String
    public let isDefault: Bool
}
private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public enum MuseAPI {
    public static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 60
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
    }
    private static func request(path: String, auth: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.muse.ai" + path)!)
        request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue("1.0.0", forHTTPHeaderField: "X-API-Version")
        request.setValue("MuseWatch/1.0 (Muse Gadget SDK compatible)", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }
    private static func perform(_ request: URLRequest) async throws -> [String: Any] {
        let session = session(); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MuseError.network("Muse returned an invalid response.") }
        if http.statusCode == 401 || http.statusCode == 403 { throw MuseError.rejectedCredentials }
        guard (200..<300).contains(http.statusCode), data.count <= 131072 else { throw MuseError.network("Muse request failed (HTTP \(http.statusCode)).") }
        return try jsonObject(data)
    }
    public static func fetchVMs(_ credentials: DeviceCredentials) async throws -> [MuseVM] {
        try credentials.validate()
        let result = try await perform(request(path: "/fetch_vms", auth: "Bearer " + credentials.accessToken))
        guard result["error_title"] == nil, result["backend_error_code"] == nil, let list = result["vm_list"] as? [[String: Any]] else { throw MuseError.network("Muse did not return an available account VM.") }
        let vms = list.compactMap { entry -> MuseVM? in
            let rawURL = entry["vm_ws_url"] as? String ?? entry["vm_url"] as? String ?? ""
            let inferred = URL(string: rawURL)?.host?.split(separator: ".").first.map(String.init) ?? ""
            let id = entry["vm_id"] as? String ?? inferred
            guard !id.isEmpty, id.utf8.count <= 512, let token = entry["vm_auth_token"] as? String, !token.isEmpty else { return nil }
            return MuseVM(id: id, name: entry["vm_name"] as? String ?? "", token: token, isDefault: entry["default"] as? Bool ?? false)
        }
        guard !vms.isEmpty else { throw MuseError.network("No Muse VM is available for this paired device.") }; return vms
    }
    public static func refresh(_ credentials: DeviceCredentials) async throws -> DeviceCredentials {
        try credentials.validate()
        let rawRefresh = credentials.refreshToken.split(separator: ":").last.map(String.init) ?? ""
        let body = try jsonData(["device_id": credentials.identity.nodeID, "sdk_token": credentials.sdkToken])
        var result = try await perform(request(path: "/device_token/refresh", auth: "Bearer hatch_refresh:" + rawRefresh, body: body))
        if let payload = result["payload"] as? [String: Any] { result = payload }
        guard let access = result["access_token"] as? String, !access.isEmpty, let refresh = result["refresh_token"] as? String, !refresh.isEmpty else { throw MuseError.network("Muse did not return both rotated credentials.") }
        var updated = credentials; updated.accessToken = access; updated.refreshToken = refresh; updated.savedAt = .now
        try updated.validate(); return updated
    }
}
