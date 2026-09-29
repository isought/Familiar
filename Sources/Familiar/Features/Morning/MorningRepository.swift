import CSQLite
import Darwin
import Foundation

struct LoadedMorningWorkspace {
    var workspace: MorningWorkspace
    var requiresSave = false
}

@MainActor
protocol MorningRepository: AnyObject {
    func load() throws -> LoadedMorningWorkspace?
    func save(_ workspace: MorningWorkspace) throws
}

/// Mutable card state lives in SQLite; timestamped source runs remain separate evidence.
/// Domain validation belongs to MorningStore. A legacy JSON file is retained unchanged.
@MainActor
final class SQLiteMorningRepository: MorningRepository {
    private let directory: URL
    private var database: URL { directory.appendingPathComponent("morning.sqlite") }
    private var legacy: URL { directory.appendingPathComponent("workspace.json") }

    init(directory: URL) { self.directory = directory }

    func load() throws -> LoadedMorningWorkspace? {
        if FileManager.default.fileExists(atPath: database.path) {
            return try withDatabase(at: database, create: false) { db in
                try checkVersion(db)
                let metadata = try blobs(db, sql: "SELECT payload FROM workspace WHERE id = 1")
                guard metadata.count == 1 else { throw MorningStoreError.unavailable("The morning database has no workspace record.") }
                var workspace = try JSONDecoder().decode(MorningWorkspace.self, from: metadata[0])
                workspace.cards = try blobs(db, sql: "SELECT payload FROM cards ORDER BY position").map { try JSONDecoder().decode(MorningCard.self, from: $0) }
                workspace.workItems = try blobs(db, sql: "SELECT payload FROM work_items ORDER BY position").map { try JSONDecoder().decode(MorningWorkItem.self, from: $0) }
                return LoadedMorningWorkspace(workspace: workspace)
            }
        }
        guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
        let data = try Data(contentsOf: legacy)
        struct Header: Decodable { var version: Int }
        let version = try JSONDecoder().decode(Header.self, from: data).version
        guard version == 1 else {
            throw MorningStoreError.unavailable("These morning files use version \(version), which this version of Noteling cannot read. Your saved files have been left untouched.")
        }
        return LoadedMorningWorkspace(workspace: try JSONDecoder().decode(MorningWorkspace.self, from: data), requiresSave: true)
    }

    func save(_ workspace: MorningWorkspace) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let creating = !manager.fileExists(atPath: database.path)
        let destination = creating ? directory.appendingPathComponent(".morning-\(UUID().uuidString).sqlite.tmp") : database
        defer { if creating { try? manager.removeItem(at: destination) } }
        try withDatabase(at: destination, create: creating) { db in
            if creating {
                try execute(db, sql: "PRAGMA user_version = 1")
                try execute(db, sql: "CREATE TABLE workspace (id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL)")
                try execute(db, sql: "CREATE TABLE cards (id TEXT PRIMARY KEY NOT NULL, tracking_key TEXT UNIQUE, position INTEGER NOT NULL, payload BLOB NOT NULL)")
                try execute(db, sql: "CREATE TABLE work_items (id TEXT PRIMARY KEY NOT NULL, position INTEGER NOT NULL, payload BLOB NOT NULL)")
            } else { try checkVersion(db) }
            try execute(db, sql: "PRAGMA synchronous = FULL")
            try execute(db, sql: "BEGIN IMMEDIATE")
            do {
                var metadata = workspace
                metadata.cards = []; metadata.workItems = []
                try execute(db, sql: "INSERT OR REPLACE INTO workspace (id, payload) VALUES (1, ?)", values: [.blob(try JSONEncoder().encode(metadata))])
                try execute(db, sql: "DELETE FROM cards")
                for (position, card) in workspace.cards.enumerated() {
                    try execute(db, sql: "INSERT INTO cards (id, tracking_key, position, payload) VALUES (?, ?, ?, ?)",
                        values: [.text(card.id.uuidString), card.tracking.map { .text($0.key) } ?? .null, .integer(position), .blob(try JSONEncoder().encode(card))])
                }
                try execute(db, sql: "DELETE FROM work_items")
                for (position, work) in workspace.workItems.enumerated() {
                    try execute(db, sql: "INSERT INTO work_items (id, position, payload) VALUES (?, ?, ?)",
                        values: [.text(work.id.uuidString), .integer(position), .blob(try JSONEncoder().encode(work))])
                }
                try execute(db, sql: "COMMIT")
            } catch {
                try? execute(db, sql: "ROLLBACK")
                throw error
            }
        }
        if creating {
            guard renamex_np(destination.path, database.path, UInt32(RENAME_EXCL)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: database.path])
            }
        }
    }

    private func withDatabase<T>(at url: URL, create: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &connection, flags, nil) == SQLITE_OK, let connection else {
            let reason = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the database."
            if let connection { sqlite3_close(connection) }
            throw MorningStoreError.unavailable("Morning database: \(reason)")
        }
        defer { sqlite3_close(connection) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        sqlite3_busy_timeout(connection, 1000)
        return try body(connection)
    }

    private func checkVersion(_ db: OpaquePointer) throws {
        let statement = try prepare(db, sql: "PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure(db) }
        let version = sqlite3_column_int(statement, 0)
        guard version == 1 else { throw MorningStoreError.unavailable("The morning database uses unsupported version \(version).") }
    }

    private enum Value { case text(String), blob(Data), integer(Int), null }
    private func execute(_ db: OpaquePointer, sql: String, values: [Value] = []) throws {
        let statement = try prepare(db, sql: sql)
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .blob(let data): result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            case .integer(let value): result = sqlite3_bind_int64(statement, index, sqlite3_int64(value))
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw failure(db) }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure(db) }
    }

    private func blobs(_ db: OpaquePointer, sql: String) throws -> [Data] {
        let statement = try prepare(db, sql: sql)
        defer { sqlite3_finalize(statement) }
        var result: [Data] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let bytes = sqlite3_column_blob(statement, 0) else { throw MorningStoreError.unavailable("A morning database record is empty.") }
                result.append(Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
            case SQLITE_DONE: return result
            default: throw failure(db)
            }
        }
    }

    private func prepare(_ db: OpaquePointer, sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure(db) }
        return statement
    }
    private func failure(_ db: OpaquePointer) -> MorningStoreError {
        .unavailable("Morning database: \(String(cString: sqlite3_errmsg(db)))")
    }
}
