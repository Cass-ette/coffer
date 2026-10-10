import XCTest
@testable import CofferCore

/// 数据安全门：证明「新代码读旧 vault」不炸。
/// 历史上丢数据的机制正是 EntryPayload 自动合成 Codable 遇到未知 case
/// 导致整文档解码失败——这些测试是防止该类回归的兼容门。
final class LegacyVaultCompatTests: XCTestCase {
    /// 2026-09 版格式：groupID 单值（含 null 情形）、无 isHidden、无任何 wallet 条目。
    /// 新代码必须能完整解码。
    ///
    /// 三个关键格式点（与真实实现逐一核对过）：
    /// - VaultDocument 必填键：schemaVersion + settings（EncryptedSettings 键名
    ///   为 autoLockSeconds / clipboardClearSeconds）
    /// - payload 的合成格式是 **camelCase case 名 + `_0` 位置包装**
    ///   （实测验证：{"apiKey":{"_0":{...}}}，无 _0 形状会解码失败）
    /// - 旧版 groupID 是单值 UUID（可为 null）；Entry 的迁移解码器
    ///   会把它转成 groupIDs 数组
    func testDecodePreWalletDocument() throws {
        let legacyGroupID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEFFFF0000"
        let json = """
        {"schemaVersion":1,
         "settings":{"autoLockSeconds":300,"clipboardClearSeconds":45},
         "entries":[{"id":"20992ED3-42C3-423A-8427-7FB42E247953","type":"api_key",
         "title":"Autobits密钥","subtitle":"个人","groupID":"\(legacyGroupID)","tags":[],
         "isFavorite":false,"permissionNote":"","customFields":[],
         "createdAt":0.0,"updatedAt":0.0,
         "payload":{"apiKey":{"_0":{"provider":"autobits","secret":"sk-x","envPrefix":""}}}},
        {"id":"8E1CF0CB-3F2C-4FBE-9E6C-B04227CB7AF1","type":"secure_note",
         "title":"旧笔记","subtitle":"","groupID":null,"tags":[],
         "isFavorite":false,"permissionNote":"","customFields":[],
         "createdAt":0.0,"updatedAt":0.0,
         "payload":{"secureNote":{"_0":{"body":"正文","attachments":[]}}}}],
         "groups":[]}
        """
        let doc = try JSONDecoder().decode(VaultDocument.self, from: Data(json.utf8))
        XCTAssertEqual(doc.entries.count, 2)
        XCTAssertEqual(doc.entries[0].title, "Autobits密钥")
        // 旧 groupID 单值必须迁移为 groupIDs 数组（且值不丢）
        XCTAssertEqual(doc.entries[0].groupIDs, [UUID(uuidString: legacyGroupID)])
        XCTAssertEqual(doc.entries[1].groupIDs, [])
        // 旧格式无 isHidden 键，解码应回落 false 而非报错
        XCTAssertFalse(doc.entries[0].isHidden)
        XCTAssertEqual(doc.settings.autoLockSeconds, 300)
        XCTAssertEqual(doc.settings.clipboardClearSeconds, 45)
    }

    /// 混合文档：老条目 + wallet 条目共存，round-trip 不丢任何一边。
    func testMixedDocumentRoundtrip() throws {
        let legacy = Entry(id: UUID(), type: .login, title: "老条目", subtitle: "",
                           groupIDs: [], tags: [], isFavorite: false, isHidden: false,
                           permissionNote: "",
                           customFields: [], createdAt: Date(), updatedAt: Date(),
                           payload: .login(LoginPayload(username: "u", password: "p", urls: [])))
        let wallet = Entry(id: UUID(), type: .wallet, title: "新钱包",
                           subtitle: "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH",
                           groupIDs: [], tags: [], isFavorite: false, isHidden: false,
                           permissionNote: "",
                           customFields: [], createdAt: Date(), updatedAt: Date(),
                           payload: .wallet(WalletPayload(chain: .tron,
                               address: "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH",
                               secretKind: .watchOnly, secret: nil,
                               derivationPath: nil, note: nil)))
        // VaultDocument init 必填 schemaVersion+settings，用 empty() 起（照 VaultStoreTests 模式）
        var doc = VaultDocument.empty()
        doc.entries = [legacy, wallet]
        let back = try JSONDecoder().decode(VaultDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back.entries.count, 2)
        XCTAssertEqual(back.entries.filter { $0.type == .wallet }.count, 1)
        XCTAssertEqual(back.entries.filter { $0.type == .login }.count, 1)
    }
}
