import XCTest
@testable import CofferCore

final class FuzzyMatchTests: XCTestCase {
    func testEmptyQueryScoresZero() {
        XCTAssertEqual(FuzzyMatch.score(query: "", in: "anything"), 0)
    }

    func testSubstringBeatsSubsequence() {
        let substring = FuzzyMatch.score(query: "pass", in: "password")
        let subsequence = FuzzyMatch.score(query: "pass", in: "PineApple StreetS")
        XCTAssertNotNil(substring)
        XCTAssertNotNil(subsequence)
        XCTAssertGreaterThan(substring!, subsequence!)
    }

    func testContiguousBeatsScattered() {
        let contiguous = FuzzyMatch.score(query: "abc", in: "xabcy")
        let scattered = FuzzyMatch.score(query: "abc", in: "axbxcx")
        XCTAssertNotNil(contiguous)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(contiguous!, scattered!)
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(FuzzyMatch.score(query: "xyz", in: "abcdef"))
    }

    func testCaseInsensitive() {
        let lower = FuzzyMatch.score(query: "test", in: "TestString")
        let upper = FuzzyMatch.score(query: "TEST", in: "teststring")
        XCTAssertNotNil(lower)
        XCTAssertNotNil(upper)
        XCTAssertEqual(lower, upper)
    }
}

final class SearchIndexTests: XCTestCase {
    func testTitleOutranksTagOutranksURL() {
        let entries = [
            Entry(id: UUID(), type: .login, title: "github", subtitle: "",
                  groupIDs: [], tags: [], isFavorite: false, isHidden: false, permissionNote: "",
                  customFields: [], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: []))),
            Entry(id: UUID(), type: .login, title: "x", subtitle: "",
                  groupIDs: [], tags: ["github"], isFavorite: false, isHidden: false, permissionNote: "",
                  customFields: [], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: []))),
            Entry(id: UUID(), type: .login, title: "y", subtitle: "",
                  groupIDs: [], tags: [], isFavorite: false, isHidden: false, permissionNote: "",
                  customFields: [], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: ["https://github.com"])))
        ]
        let index = SearchIndex(entries: entries)

        let results = index.search(query: "github")
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].title, "github")
        XCTAssertEqual(results[1].tags, ["github"])
        if case .login(let payload) = results[2].payload {
            XCTAssertEqual(payload.urls.first, "https://github.com")
        } else {
            XCTFail("Expected login payload")
        }
    }

    func testSensitiveFieldsNeverMatched() {
        let entries = [
            Entry(id: UUID(), type: .login, title: "safe", subtitle: "",
                  groupIDs: [], tags: [], isFavorite: false, isHidden: false, permissionNote: "",
                  customFields: [
                    CustomField(name: "note", value: "secret123", isSensitive: true)
                  ], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "secret123", urls: []))),
            // wallet 变体：助记词（secret）绝不可搜索命中，地址（非敏感）可以。
            Entry(id: UUID(), type: .wallet, title: "冷钱包", subtitle: "",
                  groupIDs: [], tags: [], isFavorite: false, isHidden: false, permissionNote: "",
                  customFields: [], createdAt: Date(), updatedAt: Date(),
                  payload: .wallet(WalletPayload(
                      chain: .tron, address: "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH",
                      secretKind: .mnemonic,
                      secret: "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
                      derivationPath: nil, note: nil)))
        ]
        let index = SearchIndex(entries: entries)

        // 敏感内容（密码 / 助记词）搜索不到
        XCTAssertEqual(index.search(query: "secret123").count, 0)
        XCTAssertEqual(index.search(query: "abandon").count, 0)
        XCTAssertEqual(index.search(query: "abandon about").count, 0)
        // 非敏感的地址能搜到
        XCTAssertEqual(index.search(query: "TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH").count, 1)
    }

    func testPermissionNoteLowestWeight() {
        let entries = [
            Entry(id: UUID(), type: .login, title: "a", subtitle: "",
                  groupIDs: [], tags: [], isFavorite: false, isHidden: false, permissionNote: "",
                  customFields: [
                    CustomField(name: "field", value: "match", isSensitive: false)
                  ], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: []))),
            Entry(id: UUID(), type: .login, title: "b", subtitle: "",
                  groupIDs: [], tags: [], isFavorite: false, isHidden: false, permissionNote: "match",
                  customFields: [], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: [])))
        ]
        let index = SearchIndex(entries: entries)

        let results = index.search(query: "match")
        XCTAssertEqual(results.count, 2)
        // permissionNote weight (25) > customField weight (20), so "b" ranks higher
        XCTAssertEqual(results[0].title, "b")
        XCTAssertEqual(results[1].title, "a")
    }

    func testGroupTagFiltersComposeWithQuery() {
        let group1 = UUID()
        let group2 = UUID()
        let entries = [
            Entry(id: UUID(), type: .login, title: "github work", subtitle: "",
                  groupIDs: [group1], tags: ["dev"], isFavorite: false, isHidden: false, permissionNote: "",
                  customFields: [], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: []))),
            Entry(id: UUID(), type: .login, title: "github personal", subtitle: "",
                  groupIDs: [group2], tags: ["dev"], isFavorite: false, isHidden: false, permissionNote: "",
                  customFields: [], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: []))),
            Entry(id: UUID(), type: .login, title: "slack work", subtitle: "",
                  groupIDs: [group1], tags: ["chat"], isFavorite: false, isHidden: false, permissionNote: "",
                  customFields: [], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: [])))
        ]
        let index = SearchIndex(entries: entries)

        let results = index.search(query: "github", groupID: group1, tag: "dev")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "github work")
    }

    func testEmptyQueryReturnsAllSortedByUpdatedAtDesc() {
        let old = Date(timeIntervalSince1970: 1000)
        let mid = Date(timeIntervalSince1970: 2000)
        let new = Date(timeIntervalSince1970: 3000)
        let entries = [
            Entry(id: UUID(), type: .login, title: "old", subtitle: "",
                  groupIDs: [], tags: [], isFavorite: false, isHidden: false, permissionNote: "",
                  customFields: [], createdAt: old, updatedAt: old,
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: []))),
            Entry(id: UUID(), type: .login, title: "mid", subtitle: "",
                  groupIDs: [], tags: [], isFavorite: false, isHidden: false, permissionNote: "",
                  customFields: [], createdAt: mid, updatedAt: mid,
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: []))),
            Entry(id: UUID(), type: .login, title: "new", subtitle: "",
                  groupIDs: [], tags: [], isFavorite: false, isHidden: false, permissionNote: "",
                  customFields: [], createdAt: new, updatedAt: new,
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: [])))
        ]
        let index = SearchIndex(entries: entries)

        let results = index.search(query: "")
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0].title, "new")
        XCTAssertEqual(results[1].title, "mid")
        XCTAssertEqual(results[2].title, "old")
    }
}
