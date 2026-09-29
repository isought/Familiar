import Foundation
import Testing
@testable import Familiar

/// The data folder moves from an earlier name's folder to `.noteling` exactly once, and never loses data.
@Suite
struct DataFolderMigrationTests {
    private let fm = FileManager.default

    private func makeHome() throws -> URL {
        let home = fm.temporaryDirectory.appendingPathComponent("noteling-home-\(UUID())")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func makeFolder(_ name: String, in home: URL, log: String) throws -> URL {
        let folder = home.appendingPathComponent(name)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("config.json"))
        try Data("earlier log".utf8).write(to: folder.appendingPathComponent(log))
        return folder
    }

    @Test func movesTheFamiliarFolderAndRenamesItsLog() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        let old = try makeFolder(".familiar", in: home, log: "familiar.log")

        let dir = Config.adoptDefaultDir(home: home)

        #expect(dir.path == home.appendingPathComponent(".noteling").path)
        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("config.json").path))
        #expect(try String(contentsOf: dir.appendingPathComponent("noteling.log"), encoding: .utf8) == "earlier log")
        #expect(!fm.fileExists(atPath: dir.appendingPathComponent("familiar.log").path))
    }

    @Test func movesTheSidekickFolderWhenItIsTheOnlyOne() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        _ = try makeFolder(".sidekick", in: home, log: "sidekick.log")

        let dir = Config.adoptDefaultDir(home: home)

        #expect(dir.path == home.appendingPathComponent(".noteling").path)
        #expect(fm.fileExists(atPath: dir.appendingPathComponent("noteling.log").path))
        #expect(!fm.fileExists(atPath: home.appendingPathComponent(".sidekick").path))
    }

    @Test func keepsAnExistingNotelingFolderAndLeavesOlderOnesAlone() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(at: home.appendingPathComponent(".noteling"), withIntermediateDirectories: true)
        let old = try makeFolder(".familiar", in: home, log: "familiar.log")

        #expect(Config.adoptDefaultDir(home: home).path == home.appendingPathComponent(".noteling").path)
        #expect(fm.fileExists(atPath: old.appendingPathComponent("config.json").path))
    }

    @Test func startsFreshWhenThereIsNothingToMove() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(at: home) }

        #expect(Config.adoptDefaultDir(home: home).path == home.appendingPathComponent(".noteling").path)
    }

    @Test func keepsUsingTheOldFolderWhenItCannotBeMoved() throws {
        let home = try makeHome()
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
            try? fm.removeItem(at: home)
        }
        let old = try makeFolder(".familiar", in: home, log: "familiar.log")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: home.path)   // the rename needs a writable parent

        #expect(Config.adoptDefaultDir(home: home).path == old.path)
        #expect(fm.fileExists(atPath: old.appendingPathComponent("config.json").path))
    }
}
