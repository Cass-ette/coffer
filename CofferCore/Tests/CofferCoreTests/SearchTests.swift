import XCTest
@testable import CofferCore

final class FuzzyMatchTests: XCTestCase {
    func testEmptyQueryScoresZero() {
        XCTAssertNil(FuzzyMatch.score(query: "", target: "anything"))
    }

    func testSubstringBeatsSubsequence() {
        let substring = FuzzyMatch.score(query: "pass", target: "password")
        let subsequence = FuzzyMatch.score(query: "pass", target: "PineApple StreetS")
        XCTAssertNotNil(substring)
        XCTAssertNotNil(subsequence)
        XCTAssertGreaterThan(substring!, subsequence!)
    }

    func testContiguousBeatsScattered() {
        let contiguous = FuzzyMatch.score(query: "abc", target: "xabcy")
        let scattered = FuzzyMatch.score(query: "abc", target: "axbxcx")
        XCTAssertNotNil(contiguous)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(contiguous!, scattered!)
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(FuzzyMatch.score(query: "xyz", target: "abcdef"))
    }

    func testCaseInsensitive() {
        let lower = FuzzyMatch.score(query: "test", target: "TestString")
        let upper = FuzzyMatch.score(query: "TEST", target: "teststring")
        XCTAssertNotNil(lower)
        XCTAssertNotNil(upper)
        XCTAssertEqual(lower, upper)
    }
}

final class SearchIndexTests: XCTestCase {
    func testTitleOutranksTagOutranksURL() {
        let entries = [
            Entry(id: UUID(), type: .login, title: "github", subtitle: "",
                  groupID: nil, tags: [], isFavorite: false, permissionNote: "",
                  customFields: [], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: []))),
            Entry(id: UUID(), type: .login, title: "x", subtitle: "",
                  groupID: nil, tags: ["github"], isFavorite: false, permissionNote: "",
                  customFields: [], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: []))),
            Entry(id: UUID(), type: .login, title: "y", subtitle: "",
                  groupID: nil, tags: [], isFavorite: false, permissionNote: "",
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
                  groupID: nil, tags: [], isFavorite: false, permissionNote: "",
                  customFields: [
                    CustomField(name: "note", value: "secret123", isSensitive: true)
                  ], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "secret123", urls: [])))
        ]
        let index = SearchIndex(entries: entries)

        let results = index.search(query: "secret123")
        XCTAssertEqual(results.count, 0)
    }

    func testPermissionNoteLowestWeight() {
        let entries = [
            Entry(id: UUID(), type: .login, title: "a", subtitle: "",
                  groupID: nil, tags: [], isFavorite: false, permissionNote: "",
                  customFields: [
                    CustomField(name: "field", value: "match", isSensitive: false)
                  ], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: []))),
            Entry(id: UUID(), type: .login, title: "b", subtitle: "",
                  groupID: nil, tags: [], isFavorite: false, permissionNote: "match",
                  customFields: [], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: [])))
        ]
        let index = SearchIndex(entries: entries)

        let results = index.search(query: "match")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].title, "a")
        XCTAssertEqual(results[1].title, "b")
    }

    func testGroupTagFiltersComposeWithQuery() {
        let group1 = UUID()
        let group2 = UUID()
        let entries = [
            Entry(id: UUID(), type: .login, title: "github work", subtitle: "",
                  groupID: group1, tags: ["dev"], isFavorite: false, permissionNote: "",
                  customFields: [], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: []))),
            Entry(id: UUID(), type: .login, title: "github personal", subtitle: "",
                  groupID: group2, tags: ["dev"], isFavorite: false, permissionNote: "",
                  customFields: [], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: []))),
            Entry(id: UUID(), type: .login, title: "slack work", subtitle: "",
                  groupID: group1, tags: ["chat"], isFavorite: false, permissionNote: "",
                  customFields: [], createdAt: Date(), updatedAt: Date(),
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: [])))
        ]
        let index = SearchIndex(entries: entries)

        let results = index.search(query: "github", groupID: group1, tags: ["dev"])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].title, "github work")
    }

    func testEmptyQueryReturnsAllSortedByUpdatedAtDesc() {
        let old = Date(timeIntervalSince1970: 1000)
        let mid = Date(timeIntervalSince1970: 2000)
        let new = Date(timeIntervalSince1970: 3000)
        let entries = [
            Entry(id: UUID(), type: .login, title: "old", subtitle: "",
                  groupID: nil, tags: [], isFavorite: false, permissionNote: "",
                  customFields: [], createdAt: old, updatedAt: old,
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: []))),
            Entry(id: UUID(), type: .login, title: "mid", subtitle: "",
                  groupID: nil, tags: [], isFavorite: false, permissionNote: "",
                  customFields: [], createdAt: mid, updatedAt: mid,
                  payload: .login(LoginPayload(username: "user", password: "pass", urls: []))),
            Entry(id: UUID(), type: .login, title: "new", subtitle: "",
                  groupID: nil, tags: [], isFavorite: false, permissionNote: "",
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
