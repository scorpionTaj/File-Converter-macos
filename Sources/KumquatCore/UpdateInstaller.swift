import Foundation

/// Verifies a downloaded update and prepares the new Kumquat.app for an in-place swap. The swap itself
/// happens after the running app quits (see the app's UpdateController).
public enum UpdateInstaller {
    /// The SHA-256 listed for `fileName` in a `shasum -a 256` listing ("<hex>  <name>" per line).
    public static func expectedChecksum(for fileName: String, in listing: String) -> String? {
        for line in listing.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            // shasum marks binary mode with a leading "*" on the name.
            let name = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            let hash = parts[0].lowercased()
            if name == fileName, hash.count == 64, hash.allSatisfy(\.isHexDigit) { return hash }
        }
        return nil
    }

    /// Throws unless `file` hashes to the value `listing` gives for `fileName`.
    public static func verify(_ file: URL, as fileName: String, listing: String) async throws {
        guard let expected = expectedChecksum(for: fileName, in: listing) else {
            throw KumquatError.invalidInput(L("The release's checksum list doesn't include \(fileName)."))
        }
        let actual = try await Checksum.sha256(of: file)
        guard actual == expected else {
            throw KumquatError.invalidInput(L("\(fileName) is damaged or was altered (checksum mismatch), so it wasn't installed."))
        }
    }

    /// Copies the app out of a downloaded disk image into `directory` and checks it is a valid Kumquat of the
    /// expected version. Returns the staged app.
    public static func stageApp(fromDiskImage image: URL, into directory: URL, bundleIdentifier: String,
                                version: String) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let mountPoint = directory.appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try await ProcessRunner.runChecked(SystemTool.hdiutil, ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                                "-mountpoint", mountPoint.path, image.path], timeout: 120)
        defer {
            // Detach even when staging fails; a stuck mount would block the next attempt.
            let detach = Process()
            detach.executableURL = SystemTool.hdiutil
            detach.arguments = ["detach", mountPoint.path, "-force", "-quiet"]
            try? detach.run()
            detach.waitUntilExit()
        }
        guard let source = try fm.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw KumquatError.invalidInput(L("The disk image doesn't contain an app."))
        }
        let staged = directory.appendingPathComponent(source.lastPathComponent)
        if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
        // Without extended attributes: the disk image adds Finder info that strict signature checks reject,
        // and the signature itself lives inside the bundle.
        try await ProcessRunner.runChecked(SystemTool.ditto, ["--noextattr", "--noqtn", source.path, staged.path], timeout: 300)

        let info = Bundle(url: staged)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw KumquatError.invalidInput(L("The downloaded app isn't Kumquat."))
        }
        guard let stagedVersion = info?["CFBundleShortVersionString"] as? String,
              SemanticVersion(stagedVersion) == SemanticVersion(version) else {
            throw KumquatError.invalidInput(L("The downloaded app isn't version \(version)."))
        }
        // Not --strict: macOS adds attributes (com.apple.provenance) to files apps write, which --strict
        // reports as "detritus" even on a genuine app. A changed binary or resource still fails.
        try await ProcessRunner.runChecked(SystemTool.codesign, ["--verify", "--deep", staged.path], timeout: 120)
        return staged
    }

    /// Shell script run after Kumquat quits: $1 pid to wait for, $2 installed app, $3 staged app, $4 backup path.
    /// The old app is kept until the new one is in place, and put back if the swap fails.
    public static let swapScript = #"""
    while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
    if /bin/mv "$2" "$4"; then
      if /bin/mv "$3" "$2"; then
        /bin/rm -rf "$4"
      else
        /bin/mv "$4" "$2"
      fi
    fi
    /usr/bin/open "$2"
    """#
}
