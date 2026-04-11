import Foundation

struct ConnectionTransferPayload: Codable, Sendable {
    let version: Int
    let apiBase: String
    let managementKey: String
    let createdAt: TimeInterval
}

enum ConnectionTransferCodec {
    private static let prefix = "qb1:"
    private static let defaultAPIBase = ""

    static func encode(credentials: ResolvedCredentials) throws -> String {
        let payload = ConnectionTransferPayload(
            version: 1,
            apiBase: credentials.apiBase?.absoluteString ?? defaultAPIBase,
            managementKey: credentials.managementKey,
            createdAt: Date().timeIntervalSince1970
        )
        let data = try JSONEncoder().encode(payload)
        return prefix + base64URLEncode(data)
    }

    static func decode(_ rawCode: String) throws -> ResolvedCredentials {
        let normalized = rawCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")

        guard normalized.hasPrefix(prefix) else {
            throw AppError("连接码格式不正确。")
        }

        let encoded = String(normalized.dropFirst(prefix.count))
        guard let data = base64URLDecode(encoded) else {
            throw AppError("连接码无法解析。")
        }

        let payload = try JSONDecoder().decode(ConnectionTransferPayload.self, from: data)
        guard payload.version == 1 else {
            throw AppError("连接码版本不支持。")
        }

        guard let apiBase = URL(string: payload.apiBase),
              let scheme = apiBase.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              apiBase.host != nil else {
            throw AppError("连接码里的面板地址无效。")
        }

        let managementKey = payload.managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard managementKey.isEmpty == false else {
            throw AppError("连接码里的 management key 为空。")
        }

        return ResolvedCredentials(apiBase: apiBase, managementKey: managementKey, source: .importedConnectionCode)
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }

        return Data(base64Encoded: base64)
    }
}
