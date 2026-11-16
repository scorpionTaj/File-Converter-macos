import XCTest
@testable import KumquatCore

final class UpdateInstallerTests: TemporaryDirectoryTestCase {
    let listing = """
    8fb669380e8e46c313a68da80e2c6b75e5a0fa0b44910c22571f94a20aff798d  Kumquat-0.4.2.dmg
    6559406c39c2008d660404c85048a5604d09caccabc46c149c0c9007de214732 *Kumquat-0.4.2.zip
    not-a-hash  broken.dmg
    """

    func testReadsShasumListings() {
        XCTAssertEqual(UpdateInstaller.expectedChecksum(for: "Kumquat-0.4.2.dmg", in: listing)?.prefix(8), "8fb66938")
        XCTAssertEqual(UpdateInstaller.expectedChecksum(for: "Kumquat-0.4.2.zip", in: listing)?.prefix(8), "6559406c")
        XCTAssertNil(UpdateInstaller.expectedChecksum(for: "broken.dmg", in: listing))
        XCTAssertNil(UpdateInstaller.expectedChecksum(for: "Kumquat-0.4.3.dmg", in: listing))
    }

    func testVerifyRejectsAlteredFiles() async throws {
        let file = try self.file("Kumquat-1.0.0.dmg", "disk image")
        let good = try await Checksum.sha256(of: file)
        try await UpdateInstaller.verify(file, as: "Kumquat-1.0.0.dmg", listing: "\(good)  Kumquat-1.0.0.dmg\n")
        let altered = String(repeating: "0", count: 64)
        do {
            try await UpdateInstaller.verify(file, as: "Kumquat-1.0.0.dmg", listing: "\(altered)  Kumquat-1.0.0.dmg\n")
            XCTFail("an altered file must not verify")
        } catch {}
    }

    /// A signed fake Kumquat.app inside a real disk image.
    func makeDiskImage(version: String) async throws -> URL {
        let source = directory.appendingPathComponent("dmg-source", isDirectory: true)
        let app = source.appendingPathComponent("Kumquat.app/Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appendingPathComponent("Kumquat"))
        let info: [String: Any] = ["CFBundleIdentifier": "io.github.scorpiontaj.kumquat", "CFBundleExecutable": "Kumquat",
                                   "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: source.appendingPathComponent("Kumquat.app/Contents/Info.plist"))
        try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/codesign"),
                                           ["--force", "--sign", "-", source.appendingPathComponent("Kumquat.app").path])
        let image = directory.appendingPathComponent("Kumquat-\(version).dmg")
        try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/hdiutil"),
                                           ["create", "-quiet", "-fs", "HFS+", "-srcfolder", source.path, "-volname", "Kumquat", image.path],
                                           timeout: 120)
        return image
    }

    func testStagesTheAppFromADiskImage() async throws {
        let image = try await makeDiskImage(version: "9.1.0")
        let staged = try await UpdateInstaller.stageApp(fromDiskImage: image, into: directory.appendingPathComponent("stage"),
                                                         bundleIdentifier: "io.github.scorpiontaj.kumquat", version: "9.1.0")
        XCTAssertEqual(Bundle(url: staged)?.infoDictionary?["CFBundleShortVersionString"] as? String, "9.1.0")

        do {
            _ = try await UpdateInstaller.stageApp(fromDiskImage: image, into: directory.appendingPathComponent("stage2"),
                                                   bundleIdentifier: "io.github.scorpiontaj.kumquat", version: "9.2.0")
            XCTFail("a version mismatch must be refused")
        } catch {}
        do {
            _ = try await UpdateInstaller.stageApp(fromDiskImage: image, into: directory.appendingPathComponent("stage3"),
                                                   bundleIdentifier: "com.example.other", version: "9.1.0")
            XCTFail("another app must be refused")
        } catch {}
    }
}
