import Foundation
import CofferCore
import LocalAuthentication

@main
struct CofferCLI {
    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        guard let command = args.first else {
            printUsage()
            exit(1)
        }

        do {
            switch command {
            case "list":
                try await listEntries(args: Array(args.dropFirst()))
            case "search":
                try await searchEntries(args: Array(args.dropFirst()))
            case "get":
                try await getEntry(args: Array(args.dropFirst()))
            case "add":
                try await addEntry(args: Array(args.dropFirst()))
            case "update":
                try await updateEntry(args: Array(args.dropFirst()))
            case "delete":
                try await deleteEntry(args: Array(args.dropFirst()))
            case "audit":
                try await showAudit(args: Array(args.dropFirst()))
            case "undo":
                try await undoOperation(args: Array(args.dropFirst()))
            case "auth":
                try await handleAuth(args: Array(args.dropFirst()))
            default:
                print("Unknown command: \(command)")
                printUsage()
                exit(1)
            }
        } catch {
            print("Error: \(error.localizedDescription)")
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        Coffer CLI - Password Manager Command Line Interface

        Usage:
            coffer-cli <command> [options]

        Commands:
            list [--group <name>] [--tag <tag>] [--favorites]
                List entries with optional filters

            search <query>
                Search entries by title, tags, or content

            get <id-or-title>
                Show detailed entry information

            add --type <type> --title <title> [options]
                Add a new entry (see type-specific options below)

            update <id-or-title> [options]
                Update an existing entry

            delete <id-or-title> [--force]
                Delete an entry (--force for batch operations)

            audit [--limit <n>]
                Show recent operations audit log

            undo <operation-id>
                Undo a previous operation

            auth grant --scope <read|read_write> --expires <hours> [--description <text>]
                Generate a new authorization token

            auth list
                List all valid tokens

            auth revoke <token-id>
                Revoke a token

        Entry Types:
            login, access, apiKey, sshKey, database, totp, secureNote

        Examples:
            coffer-cli list --favorites
            coffer-cli search "教务"
            coffer-cli add --type database --title "教务系统DB" \\
                --host "192.168.1.100" --port "3306" \\
                --username "admin" --password "secret123" \\
                --db-type "MySQL" --network "内网"
        """)
    }
}

// MARK: - Core Infrastructure

let vaultDir = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("cc.cassette.coffer")
let auditPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".coffer/audit.log")
let tokenManager = TokenManager()

func checkAuthorization(requireWrite: Bool = false) throws {
    guard let token = ProcessInfo.processInfo.environment["COFFER_AUTH_TOKEN"] else {
        // No token = full access (for user's own direct usage)
        return
    }

    let (valid, scope) = try tokenManager.validate(token)
    guard valid, let scope = scope else {
        throw NSError(domain: "CofferCLI", code: 403,
                     userInfo: [NSLocalizedDescriptionKey: "Invalid or expired token"])
    }

    if requireWrite && scope == .read {
        throw NSError(domain: "CofferCLI", code: 403,
                     userInfo: [NSLocalizedDescriptionKey: "Token has read-only access, write operation denied"])
    }
}

func loadVault() async throws -> VaultDocument {
    let fileStore = VaultFileStore(directory: vaultDir)
    let store = VaultStore(fileStore: fileStore)

    let dekStore = SystemDEKStore(service: "cc.cassette.coffer.dek", account: "dek1")
    let context = LAContext()
    context.localizedReason = "Access Coffer vault"

    // First try to get DEK from Keychain
    guard let dek = try dekStore.retrieve(using: context) else {
        throw NSError(domain: "CofferCLI", code: 1,
                     userInfo: [NSLocalizedDescriptionKey: "DEK not found in Keychain. Please unlock the app first."])
    }

    let envelope = try fileStore.readEnvelope()
    let doc = try store.document(from: envelope, dek: dek)
    return doc
}

func saveVault(_ doc: VaultDocument) async throws {
    let fileStore = VaultFileStore(directory: vaultDir)
    let store = VaultStore(fileStore: fileStore)

    let dekStore = SystemDEKStore(service: "cc.cassette.coffer.dek", account: "dek1")
    let context = LAContext()

    guard let dek = try dekStore.retrieve(using: context) else {
        throw NSError(domain: "CofferCLI", code: 1,
                     userInfo: [NSLocalizedDescriptionKey: "DEK not found in Keychain"])
    }

    let previous = try fileStore.readEnvelope()
    _ = try store.save(doc, dek: dek, previous: previous)
}

func logAudit(operation: String, entryTitle: String, details: String = "") {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let source = ProcessInfo.processInfo.environment["COFFER_CLI_SOURCE"] ?? "coffer-cli"
    let logLine = "\(timestamp) | \(operation) | \(entryTitle) | \(source) | \(details)\n"

    if let data = logLine.data(using: .utf8) {
        // Ensure directory exists
        let auditDir = auditPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: auditPath.path) {
            if let handle = try? FileHandle(forWritingTo: auditPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: auditPath)
        }
    }
}

// MARK: - Commands

func listEntries(args: [String]) async throws {
    try checkAuthorization(requireWrite: false)
    let doc = try await loadVault()
    var entries = doc.entries

    // Apply filters
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--group":
            guard i + 1 < args.count else { throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "--group requires a value"]) }
            let groupName = args[i + 1]
            if let group = doc.groups.first(where: { $0.name == groupName }) {
                entries = entries.filter { $0.groupIDs.contains(group.id) }
            }
            i += 2
        case "--tag":
            guard i + 1 < args.count else { throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "--tag requires a value"]) }
            let tag = args[i + 1]
            entries = entries.filter { $0.tags.contains(tag) }
            i += 2
        case "--favorites":
            entries = entries.filter { $0.isFavorite }
            i += 1
        default:
            i += 1
        }
    }

    print("Total: \(entries.count) entries\n")
    for entry in entries.sorted(by: { $0.title < $1.title }) {
        let star = entry.isFavorite ? "⭐️" : "  "
        let groupNames = entry.groupIDs.compactMap { gid in doc.groups.first(where: { $0.id == gid })?.name }
        let groupDisplay = groupNames.isEmpty ? "-" : groupNames.joined(separator: ", ")
        print("\(star) [\(entry.type.rawValue)] \(entry.title)")
        print("   ID: \(entry.id)")
        print("   Groups: \(groupDisplay)")
        if !entry.subtitle.isEmpty {
            print("   Subtitle: \(entry.subtitle)")
        }
        if !entry.tags.isEmpty {
            print("   Tags: \(entry.tags.joined(separator: ", "))")
        }
        print()
    }
}

func searchEntries(args: [String]) async throws {
    try checkAuthorization(requireWrite: false)
    guard let query = args.first else {
        throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "search requires a query"])
    }

    let doc = try await loadVault()
    let index = SearchIndex(entries: doc.entries)
    let results = index.search(query: query)

    print("Found \(results.count) matches for '\(query)'\n")
    for entry in results {
        print("[\(entry.type.rawValue)] \(entry.title)")
        print("   ID: \(entry.id)")
        if !entry.subtitle.isEmpty {
            print("   \(entry.subtitle)")
        }
        print()
    }
}

func getEntry(args: [String]) async throws {
    try checkAuthorization(requireWrite: false)
    guard let idOrTitle = args.first else {
        throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "get requires an ID or title"])
    }

    let doc = try await loadVault()
    let entry: Entry?

    if let uuid = UUID(uuidString: idOrTitle) {
        entry = doc.entries.first(where: { $0.id == uuid })
    } else {
        entry = doc.entries.first(where: { $0.title == idOrTitle })
    }

    guard let entry = entry else {
        throw NSError(domain: "CofferCLI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Entry not found"])
    }

    print("[\(entry.type.rawValue)] \(entry.title)")
    print("ID: \(entry.id)")
    print("Subtitle: \(entry.subtitle)")
    print("Favorite: \(entry.isFavorite ? "Yes" : "No")")
    print("Tags: \(entry.tags.joined(separator: ", "))")
    if !entry.permissionNote.isEmpty {
        print("\nPermission Note:")
        print(entry.permissionNote)
    }
    print("\nPayload:")
    printPayload(entry.payload)

    if !entry.customFields.isEmpty {
        print("\nCustom Fields:")
        for field in entry.customFields {
            print("  \(field.name): \(field.isSensitive ? "[SENSITIVE]" : field.value)")
        }
    }
}

func printPayload(_ payload: EntryPayload) {
    switch payload {
    case .login(let p):
        print("  Username: \(p.username)")
        print("  Password: [HIDDEN]")
        print("  URLs: \(p.urls.joined(separator: ", "))")
    case .access(let p):
        print("  Addresses: \(p.addresses.joined(separator: ", "))")
        print("  Login Method: \(p.loginMethod)")
        print("  Network: \(p.networkLocation)")
        print("  Role: \(p.roleNote)")
    case .apiKey(let p):
        print("  Provider: \(p.provider)")
        print("  Secret: [HIDDEN]")
        print("  Env Prefix: \(p.envPrefix)")
    case .sshKey(let p):
        print("  Host: \(p.host)")
        print("  User: \(p.user)")
        print("  Private Key: [HIDDEN]")
    case .database(let p):
        print("  Host: \(p.host)")
        print("  Port: \(p.port)")
        print("  Database: \(p.databaseName)")
        print("  Username: \(p.username)")
        print("  Password: [HIDDEN]")
        print("  Type: \(p.dbType)")
        print("  Network: \(p.networkLocation)")
    case .totp(let p):
        print("  Secret: [HIDDEN]")
        print("  Algorithm: \(p.algorithm)")
        print("  Digits: \(p.digits)")
        print("  Period: \(p.period)s")
    case .secureNote(let p):
        print("  Body: [HIDDEN - \(p.body.count) chars]")
        print("  Attachments: \(p.attachments.count)")
    }
}

func addEntry(args: [String]) async throws {
    try checkAuthorization(requireWrite: true)
    var doc = try await loadVault()

    var type: EntryType?
    var title = ""
    var subtitle = ""
    var groupName: String?
    var tags: [String] = []
    var isFavorite = false
    var permissionNote = ""
    var payloadArgs: [String: String] = [:]

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--type":
            guard i + 1 < args.count else { throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "--type requires a value"]) }
            type = EntryType(rawValue: args[i + 1])
            i += 2
        case "--title":
            guard i + 1 < args.count else { throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "--title requires a value"]) }
            title = args[i + 1]
            i += 2
        case "--subtitle":
            guard i + 1 < args.count else { throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "--subtitle requires a value"]) }
            subtitle = args[i + 1]
            i += 2
        case "--group":
            guard i + 1 < args.count else { throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "--group requires a value"]) }
            groupName = args[i + 1]
            i += 2
        case "--tags":
            guard i + 1 < args.count else { throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "--tags requires a value"]) }
            tags = args[i + 1].split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
            i += 2
        case "--favorite":
            isFavorite = true
            i += 1
        case "--permission-note":
            guard i + 1 < args.count else { throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "--permission-note requires a value"]) }
            permissionNote = args[i + 1]
            i += 2
        default:
            if args[i].hasPrefix("--") {
                let key = String(args[i].dropFirst(2))
                guard i + 1 < args.count else { throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(args[i]) requires a value"]) }
                payloadArgs[key] = args[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
    }

    guard let type = type else {
        throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "--type is required"])
    }
    guard !title.isEmpty else {
        throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "--title is required"])
    }

    let groupID = groupName.flatMap { name in doc.groups.first(where: { $0.name == name })?.id }
    let payload = try buildPayload(type: type, args: payloadArgs)

    let entry = Entry(
        id: UUID(),
        type: type,
        title: title,
        subtitle: subtitle,
        groupIDs: groupID.map { [$0] } ?? [],
        tags: tags,
        isFavorite: isFavorite,
        permissionNote: permissionNote,
        customFields: [],
        createdAt: Date(),
        updatedAt: Date(),
        payload: payload
    )

    doc.entries.append(entry)
    try await saveVault(doc)
    logAudit(operation: "ADD", entryTitle: title, details: "type=\(type.rawValue)")

    print("✓ Added entry '\(title)' (ID: \(entry.id))")
}

func buildPayload(type: EntryType, args: [String: String]) throws -> EntryPayload {
    switch type {
    case .login:
        let username = args["username"] ?? ""
        let password = args["password"] ?? ""
        let urls = (args["urls"] ?? "").split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
        return .login(LoginPayload(username: username, password: password, urls: urls))

    case .access:
        let addresses = (args["addresses"] ?? "").split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) }
        let loginMethod = args["login-method"] ?? "SSO"
        let network = args["network"] ?? "内网"
        let role = args["role"] ?? ""
        return .access(AccessPayload(addresses: addresses, loginMethod: loginMethod, networkLocation: network, roleNote: role))

    case .apiKey:
        let provider = args["provider"] ?? ""
        let secret = args["secret"] ?? ""
        let envPrefix = args["env-prefix"] ?? ""
        return .apiKey(APIKeyPayload(provider: provider, secret: secret, envPrefix: envPrefix))

    case .sshKey:
        let host = args["host"] ?? ""
        let user = args["user"] ?? ""
        let privateKey = args["private-key"] ?? ""
        return .sshKey(SSHKeyPayload(host: host, user: user, privateKey: privateKey))

    case .database:
        let host = args["host"] ?? ""
        let port = args["port"] ?? "3306"
        let databaseName = args["database"] ?? args["db-name"] ?? ""
        let username = args["username"] ?? ""
        let password = args["password"] ?? ""
        let dbType = args["db-type"] ?? "MySQL"
        let network = args["network"] ?? "内网"
        return .database(DatabasePayload(host: host, port: port, databaseName: databaseName, username: username, password: password, dbType: dbType, networkLocation: network))

    case .totp:
        let secret = args["secret"] ?? ""
        let algorithm = args["algorithm"] ?? "SHA1"
        let digits = Int(args["digits"] ?? "6") ?? 6
        let period = Int(args["period"] ?? "30") ?? 30
        return .totp(TOTPPayload(secretBase32: secret, algorithm: algorithm, digits: digits, period: period))

    case .secureNote:
        let body = args["body"] ?? ""
        return .secureNote(SecureNotePayload(body: body, attachments: []))
    }
}

func updateEntry(args: [String]) async throws {
    try checkAuthorization(requireWrite: true)
    guard let idOrTitle = args.first else {
        throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "update requires an ID or title"])
    }

    var doc = try await loadVault()

    let index: Int?
    if let uuid = UUID(uuidString: idOrTitle) {
        index = doc.entries.firstIndex(where: { $0.id == uuid })
    } else {
        index = doc.entries.firstIndex(where: { $0.title == idOrTitle })
    }

    guard let index = index else {
        throw NSError(domain: "CofferCLI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Entry not found"])
    }

    var entry = doc.entries[index]
    let updateArgs = Array(args.dropFirst())

    // Parse update arguments (similar to add, but optional)
    var i = 0
    var payloadArgs: [String: String] = [:]

    while i < updateArgs.count {
        switch updateArgs[i] {
        case "--title":
            guard i + 1 < updateArgs.count else { throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "--title requires a value"]) }
            entry.title = updateArgs[i + 1]
            i += 2
        case "--subtitle":
            guard i + 1 < updateArgs.count else { throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "--subtitle requires a value"]) }
            entry.subtitle = updateArgs[i + 1]
            i += 2
        case "--favorite":
            entry.isFavorite = true
            i += 1
        case "--unfavorite":
            entry.isFavorite = false
            i += 1
        default:
            if updateArgs[i].hasPrefix("--") {
                let key = String(updateArgs[i].dropFirst(2))
                guard i + 1 < updateArgs.count else { throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(updateArgs[i]) requires a value"]) }
                payloadArgs[key] = updateArgs[i + 1]
                i += 2
            } else {
                i += 1
            }
        }
    }

    if !payloadArgs.isEmpty {
        entry.payload = try buildPayload(type: entry.type, args: payloadArgs)
    }

    entry.updatedAt = Date()
    doc.entries[index] = entry
    try await saveVault(doc)
    logAudit(operation: "UPDATE", entryTitle: entry.title)

    print("✓ Updated entry '\(entry.title)'")
}

func deleteEntry(args: [String]) async throws {
    try checkAuthorization(requireWrite: true)
    guard let idOrTitle = args.first else {
        throw NSError(domain: "CofferCLI", code: 2, userInfo: [NSLocalizedDescriptionKey: "delete requires an ID or title"])
    }

    var doc = try await loadVault()

    let index: Int?
    if let uuid = UUID(uuidString: idOrTitle) {
        index = doc.entries.firstIndex(where: { $0.id == uuid })
    } else {
        index = doc.entries.firstIndex(where: { $0.title == idOrTitle })
    }

    guard let index = index else {
        throw NSError(domain: "CofferCLI", code: 3, userInfo: [NSLocalizedDescriptionKey: "Entry not found"])
    }

    let entry = doc.entries[index]
    doc.entries.remove(at: index)
    try await saveVault(doc)
    logAudit(operation: "DELETE", entryTitle: entry.title, details: "id=\(entry.id)")

    print("✓ Deleted entry '\(entry.title)'")
}

func showAudit(args: [String]) async throws {
    var limit = 20

    var i = 0
    while i < args.count {
        if args[i] == "--limit", i + 1 < args.count {
            limit = Int(args[i + 1]) ?? 20
            i += 2
        } else {
            i += 1
        }
    }

    guard FileManager.default.fileExists(atPath: auditPath.path) else {
        print("No audit log found")
        return
    }

    let content = try String(contentsOf: auditPath, encoding: .utf8)
    let lines = content.split(separator: "\n").suffix(limit)

    print("Recent operations (last \(lines.count)):\n")
    for line in lines {
        print(line)
    }
}

func undoOperation(args: [String]) async throws {
    print("Undo functionality not yet implemented")
    print("Please use the audit log to identify the operation and manually revert it")
}

func handleAuth(args: [String]) async throws {
    guard let subcommand = args.first else {
        print("Usage: coffer-cli auth <grant|list|revoke>")
        return
    }

    switch subcommand {
    case "grant":
        var scope = TokenScope.read
        var hours = 24
        var description = ""

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--scope":
                guard i + 1 < args.count else {
                    throw NSError(domain: "CofferCLI", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "--scope requires a value"])
                }
                let scopeStr = args[i + 1]
                if scopeStr == "read" {
                    scope = .read
                } else if scopeStr == "read_write" {
                    scope = .readWrite
                } else {
                    throw NSError(domain: "CofferCLI", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "Invalid scope. Use 'read' or 'read_write'"])
                }
                i += 2
            case "--expires":
                guard i + 1 < args.count else {
                    throw NSError(domain: "CofferCLI", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "--expires requires a value"])
                }
                hours = Int(args[i + 1]) ?? 24
                i += 2
            case "--description":
                guard i + 1 < args.count else {
                    throw NSError(domain: "CofferCLI", code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "--description requires a value"])
                }
                description = args[i + 1]
                i += 2
            default:
                i += 1
            }
        }

        let token = try tokenManager.grant(scope: scope, expiresIn: hours, description: description)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        print("Generated token (expires: \(formatter.string(from: token.expiresAt))):")
        print(token.id)
        print("\nExport for use:")
        print("export COFFER_AUTH_TOKEN=\"\(token.id)\"")

    case "list":
        let tokens = try tokenManager.listValid()
        if tokens.isEmpty {
            print("No valid tokens")
        } else {
            print("Valid tokens (\(tokens.count)):\n")
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            for token in tokens {
                print("ID: \(token.id)")
                print("Scope: \(token.scope.rawValue)")
                print("Created: \(formatter.string(from: token.createdAt))")
                print("Expires: \(formatter.string(from: token.expiresAt))")
                if !token.description.isEmpty {
                    print("Description: \(token.description)")
                }
                print()
            }
        }

    case "revoke":
        guard args.count > 1 else {
            throw NSError(domain: "CofferCLI", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "revoke requires a token ID"])
        }
        let tokenId = args[1]
        try tokenManager.revoke(tokenId)
        print("✓ Revoked token \(tokenId)")

    default:
        print("Unknown auth subcommand: \(subcommand)")
        print("Usage: coffer-cli auth <grant|list|revoke>")
    }
}
