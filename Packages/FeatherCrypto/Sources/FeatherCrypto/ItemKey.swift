import FeatherCore
import Foundation

/// One key per item: keyed BLAKE2b of `"feather/v1/item" || item_id` with the master key (crypto.md "Key derivations").
public enum ItemKey {
    public static func derive(masterKey: Data, itemID: ULID) throws -> Data {
        try InvalidArgument.check(masterKey, "masterKey", 32)
        return Sodium.blake2b(Data("feather/v1/item".utf8) + itemID.bytes, key: masterKey)
    }
}
