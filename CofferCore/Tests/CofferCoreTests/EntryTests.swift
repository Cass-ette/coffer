import XCTest
@testable import CofferCore

final class EntryTests: XCTestCase {
    private func encodeDecode<T: Codable & Equatable>(_ value: T) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testLoginEntryRoundtrip() throws {
        var e = Entry.fixture(type: .login)
        e.payload = .login(LoginPayload(
            username: "apt-admin",
            password: "hunter2",
            urls: ["https://abdnims.scnu.edu.cn", "http://10.1.2.3"]
        ))
        let back = try encodeDecode(e)
        XCTAssertEqual(back, e)
    }

    func testAllSixPayloadsRoundtrip() throws {
        let payloads: [EntryPayload] = [
            .login(LoginPayload(username: "u", password: "p", urls: [])),
            .access(AccessPayload(addresses: ["http://10.0.0.1"], loginMethod: "SSO", networkLocation: "内网", roleNote: "管理员")),
            .apiKey(APIKeyPayload(provider: "deepseek", secret: "sk-xxx", envPrefix: "DEEPSEEK_API_KEY")),
            .sshKey(SSHKeyPayload(host: "server1", user: "root", privateKey: "-----BEGIN OPENSSH...")),
            .totp(TOTPPayload(secretBase32: "JBSWY3DPEHPK3PXP", algorithm: "SHA1", digits: 6, period: 30)),
            .secureNote(SecureNotePayload(body: "恢复码", attachments: [
                Attachment(fileName: "id.jpg", mimeType: "image/jpeg", dataBase64: "aGVsbG8=")
            ])),
        ]
        for p in payloads {
            var e = Entry.fixture(type: nil)
            e.payload = p
            let back = try encodeDecode(e)
            XCTAssertEqual(back.payload, p)
        }
    }

    func testUnknownEntryTypeThrows() {
        let json = #"{"id":"\#(UUID().uuidString)","type":"wat","title":"x","subtitle":"","groupID":null,"tags":[],"isFavorite":false,"permissionNote":"","customFields":[],"createdAt":0.0,"updatedAt":0.0,"payload":{"login":{"username":"a","password":"b","urls":[]}}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(Entry.self, from: Data(json.utf8)))
    }
}

extension Entry {
    static func fixture(type: EntryType?) -> Entry {
        Entry(
            id: UUID(), type: type ?? .login, title: "APT 预约系统", subtitle: "apt-admin",
            groupID: nil, tags: ["内网"], isFavorite: false, permissionNote: "管理员",
            customFields: [CustomField(name: "机房", value: "3 栋", isSensitive: false)],
            createdAt: Date(timeIntervalSinceReferenceDate: 0), updatedAt: Date(timeIntervalSinceReferenceDate: 0),
            payload: .login(LoginPayload(username: "", password: "", urls: []))
        )
    }
}
