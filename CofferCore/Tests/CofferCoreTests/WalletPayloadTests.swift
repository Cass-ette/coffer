import XCTest
@testable import CofferCore

final class WalletPayloadTests: XCTestCase {
    func testWalletRoundtrip() throws {
        let p = WalletPayload(
            chain: .tron,
            address: "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH",
            secretKind: .mnemonic,
            secret: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
            derivationPath: "m/44'/195'/0'/0/0",
            note: "测试钱包"
        )
        let e = Entry(id: UUID(), type: .wallet, title: "测试钱包",
                      subtitle: "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH", groupIDs: [],
                      tags: [], isFavorite: false, isHidden: false, permissionNote: "",
                      customFields: [],
                      createdAt: Date(), updatedAt: Date(), payload: .wallet(p))
        let data = try JSONEncoder().encode(e)
        let back = try JSONDecoder().decode(Entry.self, from: data)
        XCTAssertEqual(back, e)
        if case .wallet(let q) = back.payload {
            XCTAssertEqual(q.address, p.address)
            XCTAssertEqual(q.secret, p.secret)
        } else { XCTFail("payload 不是 wallet") }
    }

    /// 不变量：watchOnly 钱包不携带 secret——即使调用方误传非 nil 也被 init 归一化为 nil。
    func testWatchOnlyHasNoSecret() {
        let p = WalletPayload(chain: .tron, address: "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH",
                              secretKind: .watchOnly, secret: "abandon abandon about",
                              derivationPath: nil, note: nil)
        XCTAssertNil(p.secret)
    }

    /// 解码同样维持 watchOnly ⇒ 无 secret 不变量：合成 Codable 会绕过 init 归一化，
    /// watchOnly + 非 nil secret 的（旧/损坏）数据不允许把 secret 带出来。
    func testWatchOnlyDecodeNormalizesSecret() throws {
        let json = #"{"chain":"tron","address":"TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH","secretKind":"watchOnly","secret":"leak","derivationPath":null,"note":null}"#
        let p = try JSONDecoder().decode(WalletPayload.self, from: Data(json.utf8))
        XCTAssertNil(p.secret, "watchOnly 解码后 secret 必须为 nil")
        XCTAssertEqual(p.secretKind, .watchOnly)
        XCTAssertEqual(p.address, "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH")
    }

    func testWalletTypeRawValue() {
        XCTAssertEqual(EntryType.wallet.rawValue, "wallet")
    }
}
