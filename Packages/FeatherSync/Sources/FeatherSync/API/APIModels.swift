import Foundation

// The schemas of sync-protocol.openapi.yaml. Binary values are Data (standard base64), timestamps Date.

public struct ServerInfo: Codable, Sendable, Equatable {
    public var apiVersion: Int
    public var serverVersion: String
    public var billingEnabled: Bool
    public var maxBlobBytes: Int64
    public var defaultQuotaBytes: Int64
    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version", serverVersion = "server_version", billingEnabled = "billing_enabled",
             maxBlobBytes = "max_blob_bytes", defaultQuotaBytes = "default_quota_bytes"
    }
}

public struct KDF: Codable, Sendable, Equatable {
    public var alg: String
    public var t: Int
    public var mKiB: Int
    public var p: Int
    enum CodingKeys: String, CodingKey { case alg, t, mKiB = "m_kib", p }
    public init(alg: String, t: Int, mKiB: Int, p: Int) { self.alg = alg; self.t = t; self.mKiB = mKiB; self.p = p }
}

public struct CloudPlan: Codable, Sendable, Equatable {
    public var state: String
    public var reason: String?
    public var trialEndsAt: Date?
    public var quotaBytes: Int64
    public var usedBytes: Int64
    enum CodingKeys: String, CodingKey {
        case state, reason, trialEndsAt = "trial_ends_at", quotaBytes = "quota_bytes", usedBytes = "used_bytes"
    }
    public init(state: String, reason: String?, trialEndsAt: Date?, quotaBytes: Int64, usedBytes: Int64) {
        self.state = state; self.reason = reason; self.trialEndsAt = trialEndsAt; self.quotaBytes = quotaBytes; self.usedBytes = usedBytes
    }
}

public struct CloudAccount: Codable, Sendable, Equatable {
    public var email: String
    public var libraryID: String
    public var plan: CloudPlan
    public var billingEnabled: Bool
    enum CodingKeys: String, CodingKey { case email, libraryID = "library_id", plan, billingEnabled = "billing_enabled" }
    public init(email: String, libraryID: String, plan: CloudPlan, billingEnabled: Bool) {
        self.email = email; self.libraryID = libraryID; self.plan = plan; self.billingEnabled = billingEnabled
    }
}

public struct CloudDevice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var lastSeenAt: Date
    public var current: Bool
    enum CodingKeys: String, CodingKey { case id, name, createdAt = "created_at", lastSeenAt = "last_seen_at", current }
}

public struct BlobRef: Codable, Sendable, Equatable {
    public var sha256: String
    public var size: Int64
}

public struct RemoteItem: Codable, Sendable, Equatable {
    public var id: String
    public var type: String
    public var version: Int64
    public var seq: Int64
    public var deleted: Bool
    public var meta: Data?
    public var blob: BlobRef?
    public var updatedAt: Date
    enum CodingKeys: String, CodingKey { case id, type, version, seq, deleted, meta, blob, updatedAt = "updated_at" }
}

public struct Change: Codable, Sendable, Equatable {
    public var id: String
    public var type: String
    public var baseVersion: Int64
    public var deleted: Bool
    public var meta: Data?
    public var blobSHA256: String?
    enum CodingKeys: String, CodingKey { case id, type, baseVersion = "base_version", deleted, meta, blobSHA256 = "blob_sha256" }

    public init(id: String, type: String, baseVersion: Int64, deleted: Bool, meta: Data?, blobSHA256: String?) {
        self.id = id; self.type = type; self.baseVersion = baseVersion; self.deleted = deleted; self.meta = meta; self.blobSHA256 = blobSHA256
    }

    // null values are sent as null, not left out (the contract requires every field)
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(baseVersion, forKey: .baseVersion)
        try c.encode(deleted, forKey: .deleted)
        try c.encode(meta, forKey: .meta)
        try c.encode(blobSHA256, forKey: .blobSHA256)
    }
}

public enum PushResult: Decodable, Sendable, Equatable {
    case accepted(id: String, version: Int64, seq: Int64)
    case conflict(id: String, current: RemoteItem)
    case rejected(id: String, code: String)

    enum CodingKeys: String, CodingKey { case id, status, version, seq, current, error }
    struct Code: Decodable { var code: String }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        switch try c.decode(String.self, forKey: .status) {
        case "accepted": self = .accepted(id: id, version: try c.decode(Int64.self, forKey: .version), seq: try c.decode(Int64.self, forKey: .seq))
        case "conflict": self = .conflict(id: id, current: try c.decode(RemoteItem.self, forKey: .current))
        default: self = .rejected(id: id, code: try c.decode(Code.self, forKey: .error).code)
        }
    }

    public var id: String {
        switch self { case let .accepted(id, _, _), let .conflict(id, _), let .rejected(id, _): id }
    }
}

public struct PullPage: Decodable, Sendable, Equatable {
    public var items: [RemoteItem]
    public var cursor: String
    public var hasMore: Bool
    enum CodingKeys: String, CodingKey { case items, cursor, hasMore = "has_more" }
}

public struct SessionResponse: Decodable, Sendable {
    public var token: String
    public var deviceID: String
    public var account: CloudAccount?
    public var wrappedMasterPassword: Data?
    public var wrappedMasterRecovery: Data?
    enum CodingKeys: String, CodingKey {
        case token, deviceID = "device_id", account, wrappedMasterPassword = "wrapped_master_password",
             wrappedMasterRecovery = "wrapped_master_recovery"
    }
}

public struct SignupRequest: Encodable, Sendable {
    public var email: String
    public var salt: Data
    public var kdf: KDF
    public var authKey: Data
    public var recoveryAuthKey: Data
    public var wrappedMasterPassword: Data
    public var wrappedMasterRecovery: Data
    public var libraryID: String
    enum CodingKeys: String, CodingKey {
        case email, salt, kdf, authKey = "auth_key", recoveryAuthKey = "recovery_auth_key",
             wrappedMasterPassword = "wrapped_master_password", wrappedMasterRecovery = "wrapped_master_recovery", libraryID = "library_id"
    }
}

public struct SetPasswordRequest: Encodable, Sendable {
    public var currentAuthKey: Data?
    public var salt: Data
    public var kdf: KDF
    public var authKey: Data
    public var wrappedMasterPassword: Data
    enum CodingKeys: String, CodingKey {
        case currentAuthKey = "current_auth_key", salt, kdf, authKey = "auth_key", wrappedMasterPassword = "wrapped_master_password"
    }
}
