import Foundation

/// "1.2.3", "v1.2.3" or "1.2.3-beta.2". Pre-releases sort before their release.
public struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    /// Text after "-", e.g. "beta.2"; nil for a release.
    public let prerelease: String?

    public init?(_ text: String) {
        var string = text.trimmingCharacters(in: .whitespaces)
        if string.hasPrefix("v") || string.hasPrefix("V") { string.removeFirst() }
        let parts = string.split(separator: "-", maxSplits: 1)
        guard let core = parts.first else { return nil }
        let numbers = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(numbers.count), numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        major = numbers[0]!
        minor = numbers.count > 1 ? numbers[1]! : 0
        patch = numbers.count > 2 ? numbers[2]! : 0
        prerelease = parts.count > 1 ? String(parts[1]) : nil
    }

    public var isPrerelease: Bool { prerelease != nil }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil), (nil, _): return false
        case (_, nil): return true
        case let (l?, r?): return l.compare(r, options: .numeric) == .orderedAscending
        }
    }

    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

/// A GitHub release, as returned by the REST API.
public struct ReleaseInfo: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let browserDownloadURL: URL
        public let size: Int

        enum CodingKeys: String, CodingKey {
            case name, size
            case browserDownloadURL = "browser_download_url"
        }
    }

    public let tagName: String
    public let name: String?
    public let body: String?
    public let htmlURL: URL
    public let prerelease: Bool
    public let draft: Bool
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case name, body, prerelease, draft, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    public init(tagName: String, name: String? = nil, body: String? = nil, htmlURL: URL, prerelease: Bool = false,
                draft: Bool = false, assets: [Asset] = []) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.prerelease = prerelease
        self.draft = draft
        self.assets = assets
    }

    public var version: SemanticVersion? { SemanticVersion(tagName) }

    /// The disk image to download, if the release has one.
    public var diskImage: Asset? { assets.first { $0.name.lowercased().hasSuffix(".dmg") } }

    /// The `shasum -a 256` listing the release workflow publishes.
    public var checksums: Asset? { assets.first { $0.name == "SHA256SUMS.txt" } }
}

/// Finds newer releases on GitHub. No account or framework needed: the public Releases API is enough.
public enum UpdateChecker {
    public static let releasesURL = URL(string: "https://api.github.com/repos/scorpionTaj/Kumquat/releases?per_page=30")!

    /// The newest release above `current`. Drafts and tags that aren't versions (e.g. "nightly") are ignored;
    /// pre-releases only count when asked for.
    public static func newest(in releases: [ReleaseInfo], than current: String, includePrereleases: Bool) -> ReleaseInfo? {
        guard let installed = SemanticVersion(current) else { return nil }
        let candidates = releases
            .filter { !$0.draft && (includePrereleases || !$0.prerelease) }
            .compactMap { release in release.version.map { (release: release, version: $0) } }
            .filter { (includePrereleases || !$0.version.isPrerelease) && $0.version > installed }
        return candidates.max { $0.version < $1.version }?.release
    }

    public enum CheckError: LocalizedError {
        case unreachable(Int)

        public var errorDescription: String? {
            switch self {
            case .unreachable(let status):
                return status == 404
                    ? "No public releases were found (the repository may be private)."
                    : "GitHub answered with status \(status)."
            }
        }
    }

    public static func fetchReleases(session: URLSession = .shared) async throws -> [ReleaseInfo] {
        var request = URLRequest(url: releasesURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Kumquat", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CheckError.unreachable(status) }
        return try JSONDecoder().decode([ReleaseInfo].self, from: data)
    }
}
