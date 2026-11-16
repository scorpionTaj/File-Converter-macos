import XCTest
@testable import KumquatCore

final class CommandLineToolTests: TemporaryDirectoryTestCase {
    let fm = FileManager.default

    func makeApp(_ folder: String) throws -> URL {
        let app = directory.appendingPathComponent("\(folder)/Kumquat.app")
        let bin = app.appendingPathComponent("Contents/Resources/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        fm.createFile(atPath: bin.appendingPathComponent("kumquat-cli").path, contents: Data("#!/bin/sh\n".utf8),
                      attributes: [.posixPermissions: 0o755])
        return app
    }

    func folder(_ name: String) throws -> String {
        let path = directory.appendingPathComponent(name).path
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func testInstallsOnceAndRepairsAfterTheAppMoves() throws {
        let app = try makeApp("Applications"), moved = try makeApp("Moved")
        let brew = try folder("brew"), local = try folder("local")

        let link = try XCTUnwrap(CommandLineTool.install(app: app, directories: [brew, local]))
        XCTAssertEqual(link.path, brew + "/kumquat-cli")
        XCTAssertEqual(CommandLineTool.status(app: app, directories: [brew, local]), .linked(link))
        XCTAssertEqual(try CommandLineTool.install(app: app, directories: [brew, local]), link)

        XCTAssertEqual(try CommandLineTool.install(app: moved, directories: [brew, local])?.path, brew + "/kumquat-cli")
        XCTAssertTrue(try fm.destinationOfSymbolicLink(atPath: brew + "/kumquat-cli").contains("/Moved/"))
        XCTAssertEqual(CommandLineTool.status(app: app, directories: [brew, local]), .notLinked)
    }

    func testNeverReplacesSomeoneElsesFile() throws {
        let app = try makeApp("Applications")
        let taken = try folder("taken"), free = try folder("free"), broken = try folder("broken")
        try Data("other".utf8).write(to: URL(fileURLWithPath: taken + "/kumquat-cli"))
        try fm.createSymbolicLink(atPath: broken + "/kumquat-cli", withDestinationPath: "/nowhere/else")

        XCTAssertNil(try CommandLineTool.install(app: app, directories: [taken, broken]))
        XCTAssertEqual(try String(contentsOfFile: taken + "/kumquat-cli", encoding: .utf8), "other")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: broken + "/kumquat-cli"), "/nowhere/else")
        XCTAssertEqual(try CommandLineTool.install(app: app, directories: [taken, free])?.path, free + "/kumquat-cli")
    }

    func testRepairsItsOwnBrokenLinkAndSkipsUnusableFolders() throws {
        let app = try makeApp("Applications")
        let ours = try folder("ours")
        try fm.createSymbolicLink(atPath: ours + "/kumquat-cli",
                                  withDestinationPath: "/Gone/Kumquat.app/Contents/Resources/bin/kumquat-cli")
        XCTAssertEqual(try CommandLineTool.install(app: app, directories: [ours])?.path, ours + "/kumquat-cli")

        let readOnly = try folder("readonly")
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnly)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnly) }
        XCTAssertNil(try CommandLineTool.install(app: app, directories: [readOnly, directory.path + "/missing"]))

        XCTAssertThrowsError(try CommandLineTool.install(app: directory.appendingPathComponent("None.app"), directories: [ours]))
    }
}
