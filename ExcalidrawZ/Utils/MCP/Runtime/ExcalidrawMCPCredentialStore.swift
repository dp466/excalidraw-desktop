import Foundation
import Security
import LocalAuthentication

enum ExcalidrawMCPClientKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claudeCode, vscode
    var id: Self { self }
    var title: String {
        switch self {
            case .codex: "Codex"
            case .claudeCode: "Claude Code"
            case .vscode: "VS Code"
        }
    }
}

struct ExcalidrawMCPClientCredential: Identifiable, Codable, Sendable {
    let id: UUID
    let kind: ExcalidrawMCPClientKind
    let createdAt: Date
    let token: String
    var summary: ExcalidrawMCPClientSummary { .init(id: id, kind: kind, createdAt: createdAt) }
}

/// Only non-secret summaries are published to SwiftUI.
struct ExcalidrawMCPClientSummary: Identifiable, Sendable {
    let id: UUID
    let kind: ExcalidrawMCPClientKind
    let createdAt: Date
}

struct ExcalidrawMCPCredentialStore: Sendable {
    private let service: String
    init(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.chocoford.excalidraw") {
        service = "\(bundleIdentifier).mcp.clients"
    }

    func listClients() throws -> [ExcalidrawMCPClientSummary] {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]) { _, value in value } as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainFailure(status: status, operation: "list") }
        // macOS's file-based Keychain rejects MatchLimitAll + ReturnData.
        // Summaries come from non-secret attributes (no decryption, so no Keychain
        // access prompt); only items created before the label existed read the secret.
        let entries = (result as? [[String: Any]]) ?? (result as? [String: Any]).map { [$0] } ?? []
        return try entries.compactMap { attributes in
            guard let account = attributes[kSecAttrAccount as String] as? String,
                  let id = UUID(uuidString: account) else { return nil }
            if let label = attributes[kSecAttrLabel as String] as? String,
               let kind = ExcalidrawMCPClientKind(rawValue: label),
               let createdAt = attributes[kSecAttrCreationDate as String] as? Date {
                return ExcalidrawMCPClientSummary(id: id, kind: kind, createdAt: createdAt)
            }
            return try credential(id: id)?.summary
        }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func createClient(kind: ExcalidrawMCPClientKind) throws -> ExcalidrawMCPClientSummary {
        var random = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        guard randomStatus == errSecSuccess else { throw KeychainFailure(status: randomStatus, operation: "generate") }
        let id = UUID()
        let secret = Data(random).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let credential = ExcalidrawMCPClientCredential(
            id: id, kind: kind, createdAt: Date(), token: "exz_\(id.uuidString).\(secret)"
        )
        let data = try JSONEncoder().encode(credential)
        var attributes = accountQuery(id)
        attributes[kSecValueData as String] = data
        // Non-secret kind, so listing clients never needs to decrypt the token.
        attributes[kSecAttrLabel as String] = kind.rawValue
#if !os(macOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
#endif
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainFailure(status: status, operation: "create") }
        return credential.summary
    }

    func credential(id: UUID) throws -> ExcalidrawMCPClientCredential? {
        var lookup = accountQuery(id).merging([
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]) { _, value in value }
#if os(macOS)
        // The file-based Keychain uses its compatibility option to keep HTTP
        // authentication noninteractive.
        lookup[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
#else
        let context = LAContext()
        context.interactionNotAllowed = true
        lookup[kSecUseAuthenticationContext as String] = context
#endif
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainFailure(status: status, operation: "read") }
        return try JSONDecoder().decode(ExcalidrawMCPClientCredential.self, from: data)
    }

    /// A missing/revoked token always fails closed. Metadata never grants identity.
    func authenticate(authorization: String?) throws -> String? {
        guard let authorization, authorization.lowercased().hasPrefix("bearer ") else { return nil }
        let token = String(authorization.dropFirst(7))
        guard token.hasPrefix("exz_"), token.utf8.count < 200,
              let delimiter = token.firstIndex(of: "."),
              let id = UUID(uuidString: String(token[token.index(token.startIndex, offsetBy: 4)..<delimiter])),
              let credential = try credential(id: id),
              Self.constantTimeEqual(token, credential.token) else { return nil }
        return id.uuidString
    }

    func revoke(id: UUID) throws {
        let status = SecItemDelete(accountQuery(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status, operation: "revoke") }
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8), right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private func accountQuery(_ id: UUID) -> [String: Any] {
        query.merging([kSecAttrAccount as String: id.uuidString]) { _, value in value }
    }
    private var query: [String: Any] {
        // The local Mac fork is also distributed unsigned. Data Protection
        // Keychain requires signing entitlements (-34018 in the native test).
        // macOS therefore uses encrypted login Keychain generic passwords;
        // iOS uses its normal Data Protection Keychain. No plaintext fallback.
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }
    struct KeychainFailure: LocalizedError {
        let status: OSStatus
        let operation: String
        var errorDescription: String? { "MCP credential Keychain \(operation) failed (\(status))." }
    }
}

enum ExcalidrawMCPClientConfiguration {
    static func configuration(kind: ExcalidrawMCPClientKind, endpoint: String, token: String) -> String {
        switch kind {
            case .codex:
                return """
                [mcp_servers.excalidrawdesktop]
                url = "\(endpoint)"
                http_headers = { Authorization = "Bearer \(token)" }
                """
            case .claudeCode:
                return "claude mcp add --transport http --scope user excalidrawdesktop \(endpoint) --header 'Authorization: Bearer \(token)'"
            case .vscode:
                return """
                {"servers":{"excalidrawdesktop":{"type":"http","url":"\(endpoint)","headers":{"Authorization":"Bearer \(token)"}}}}
                """
        }
    }
}
