import XCTest
@testable import CofferCore

final class ServerPayloadTests: XCTestCase {
    func testServerRoundTripAndDiskShape() throws {
        let server = ServerPayload(host: "prod.example.com", port: 2222, username: "deploy", authentication: .password,
            password: "password-secret-marker", privateKey: "private-key-marker", passphrase: "key-passphrase-marker", networkLocation: "内网")
        let payload = EntryPayload.server(server)
        let data = try JSONEncoder().encode(payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let box = try XCTUnwrap(object["server"] as? [String: Any])
        let value = try XCTUnwrap(box["_0"] as? [String: Any])
        XCTAssertEqual(value["port"] as? Int, 2222)
        XCTAssertEqual(value["password"] as? String, server.password)
        XCTAssertEqual(try JSONDecoder().decode(EntryPayload.self, from: data), payload)
    }
    func testSearchFindsHostButNeverServerCredentials() {
        let payload = ServerPayload(host: "private-host.example", port: 22, username: "sensitive-login-name",
            authentication: .privateKey, password: "unique-password-839", privateKey: "unique-private-key-873",
            passphrase: "unique-passphrase-657", networkLocation: "内网")
        let entry = Entry(type: .server, title: "生产服务器", subtitle: "", groupIDs: [], tags: [], isFavorite: false,
            isHidden: false, permissionNote: "", customFields: [], createdAt: Date(), updatedAt: Date(), payload: .server(payload))
        let index = SearchIndex(entries: [entry])
        XCTAssertEqual(index.search(query: "private-host.example").count, 1)
        for secret in [payload.username, payload.password, payload.privateKey, payload.passphrase] {
            XCTAssertTrue(index.search(query: secret).isEmpty)
        }
    }
    func testSSHCommandHasNoCredentialsAndRejectsOptionOrShellInjection() throws {
        var payload = ServerPayload(host: "prod.example.com", port: 2222, username: "deploy", password: "secret")
        XCTAssertEqual(payload.sshCommand, "ssh -p 2222 -l 'deploy' -- 'prod.example.com'")
        XCTAssertFalse(payload.sshCommand!.contains(payload.password))
        for host in ["-oProxyCommand=evil", "$(touch /tmp/unsafe)", "host;evil", "ssh://example.com", "host\nother"] {
            payload.host = host
            XCTAssertNotNil(payload.connectionError)
            XCTAssertNil(payload.sshCommand)
        }
        payload.host = "2001:db8::1"
        XCTAssertNil(payload.connectionError)
        payload.username = "root' ; evil"
        XCTAssertNil(payload.sshCommand)
        payload.username = "root"
        payload.port = 0
        XCTAssertNil(payload.sshCommand)
        payload.port = 65536
        XCTAssertNotNil(payload.connectionError)
    }
    func testInvalidFutureServerPayloadIsPreservedAsUnknown() throws {
        let data = Data(#"{"server":{"_0":{"host":"example.com","authentication":"future-mode","extra":"preserve"}}}"#.utf8)
        let payload = try JSONDecoder().decode(EntryPayload.self, from: data)
        guard case .unknown = payload else { return XCTFail("preserve unrecognized data") }
        let again = try JSONEncoder().encode(payload)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: again) as? NSDictionary)
    }
}
