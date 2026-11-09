import CryptoKit
import Foundation

/// A release version such as `0.2.1` or tag `v0.2.1`, compared number by number, so 0.10.0 is newer than 0.9.9.
public struct ReleaseVersion: Comparable, CustomStringConvertible, Sendable {
    /// Major, minor and patch; a missing minor or patch counts as 0.
    public let numbers: [Int]
    /// A `-beta`-style suffix. Such versions are never offered as updates.
    public let isPrerelease: Bool

    public init?(_ text: String) {
        var value = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if value.first == "v" || value.first == "V" { value = value.dropFirst() }
        var prerelease = false
        if let suffix = value.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            prerelease = value[suffix] == "-"
            value = value[..<suffix]
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 9, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part) else { return nil }
            numbers.append(number)
        }
        self.numbers = numbers + Array(repeating: 0, count: 3 - numbers.count)
        isPrerelease = prerelease
    }

    public var description: String { numbers.map(String.init).joined(separator: ".") }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        return lhs.isPrerelease && !rhs.isPrerelease
    }
}

/// The fields of a GitHub release that the updater reads.
public struct Release: Decodable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        public let url: URL

        enum CodingKeys: String, CodingKey {
            case name
            case url = "browser_download_url"
        }
    }

    public let tag: String
    public let page: URL?
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name", page = "html_url", draft, prerelease, assets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tag = try container.decode(String.self, forKey: .tag)
        page = try container.decodeIfPresent(URL.self, forKey: .page)
        draft = try container.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try container.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        assets = try container.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }
}

/// A newer published release and the two assets the updater downloads from it.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: ReleaseVersion
    public let archive: Release.Asset
    public let checksums: Release.Asset
    public let page: URL
}

public enum UpdateError: LocalizedError, Equatable {
    case feed(String)
    case missingAsset(String, version: String)
    case checksumMissing(String)
    case checksumMismatch(String)
    case wrongBundle(String)
    case notWritable(String)

    public var errorDescription: String? {
        switch self {
        case .feed(let text): return text
        case let .missingAsset(name, version):
            return "Release \(version) has no \(name), so it can't be installed from here. Use its release page."
        case .checksumMissing(let name): return "SHA256SUMS has no checksum for \(name). Nothing was installed."
        case .checksumMismatch(let name):
            return "The SHA-256 checksum of \(name) doesn't match SHA256SUMS. The download may be damaged or " +
                   "altered, so nothing was installed."
        case .wrongBundle(let text): return text + " Nothing was installed."
        case .notWritable(let folder):
            return "macOS Lens can't replace itself in \(folder) because this account can't change that folder."
        }
    }
}

/// Where updates come from, and how a release is checked before anything is downloaded or installed.
public enum UpdateFeed {
    public static let latest = URL(string: "https://api.github.com/repos/SharonHart/macos-lens/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/SharonHart/macos-lens/releases/latest")!
    /// A release JSON for tests: an http(s) or file URL, or a file path.
    public static let environmentKey = "MACOS_LENS_UPDATE_FEED"
    public static let bundleID = "dev.macos-lens.client"
    public static let checksumsName = "SHA256SUMS"

    public static func archiveName(for version: ReleaseVersion) -> String { "macOS-Lens-\(version).zip" }

    public static func url(environment: [String: String]) -> URL {
        guard let value = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return latest }
        if let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["https", "http", "file"].contains(scheme) {
            return url
        }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }

    /// The newest published release in `releases/latest` (one object) or a `releases` list. Drafts, prereleases
    /// and tags that aren't versions are skipped.
    public static func latestRelease(from data: Data) throws -> (Release, ReleaseVersion)? {
        let decoder = JSONDecoder()
        let releases: [Release]
        if let one = try? decoder.decode(Release.self, from: data) {
            releases = [one]
        } else if let list = try? decoder.decode([Release].self, from: data) {
            releases = list
        } else {
            struct Message: Decodable { let message: String }
            let message = (try? decoder.decode(Message.self, from: data))?.message
            throw UpdateError.feed("The update feed answered " + (message.map { "“\($0)”" } ?? "with something unexpected") + ".")
        }
        return releases.compactMap { release -> (Release, ReleaseVersion)? in
            guard !release.draft, !release.prerelease, let version = ReleaseVersion(release.tag),
                  !version.isPrerelease else { return nil }
            return (release, version)
        }.max { $0.1 < $1.1 }
    }

    /// The zip and SHA256SUMS of `release`, matched by exact name.
    public static func assets(of release: Release, version: ReleaseVersion) throws -> (archive: Release.Asset, checksums: Release.Asset) {
        let name = archiveName(for: version)
        guard let archive = release.assets.first(where: { $0.name == name }) else {
            throw UpdateError.missingAsset(name, version: version.description)
        }
        guard let checksums = release.assets.first(where: { $0.name == checksumsName }) else {
            throw UpdateError.missingAsset(checksumsName, version: version.description)
        }
        return (archive, checksums)
    }

    public enum Outcome: Equatable {
        case upToDate(ReleaseVersion)
        case available(AvailableUpdate)
    }

    public static func evaluate(_ data: Data, current: String) throws -> Outcome {
        guard let installed = ReleaseVersion(current) else {
            throw UpdateError.feed("This build's version (\(current)) can't be compared with releases.")
        }
        guard let (release, version) = try latestRelease(from: data) else {
            throw UpdateError.feed("No published release was found.")
        }
        guard installed < version else { return .upToDate(installed) }
        let (archive, checksums) = try assets(of: release, version: version)
        let page = release.page ?? releasesPage
        return .available(AvailableUpdate(version: version, archive: archive, checksums: checksums, page: page))
    }

    /// The unzipped app must be macOS Lens at exactly the release's version.
    public static func validate(info: [String: Any]?, expected version: ReleaseVersion) throws {
        let identifier = info?["CFBundleIdentifier"] as? String
        guard identifier == bundleID else {
            throw UpdateError.wrongBundle("The downloaded app is \(identifier ?? "not an app"), not \(bundleID).")
        }
        let shown = info?["CFBundleShortVersionString"] as? String
        guard let shown, let found = ReleaseVersion(shown), found == version else {
            throw UpdateError.wrongBundle("The downloaded app is version \(shown ?? "unknown"), not \(version).")
        }
    }
}

/// `shasum -a 256` output, as published in each release's SHA256SUMS.
public enum Checksums {
    /// File name to lowercase hex digest. Lines are `<digest>  <name>` or `<digest> *<name>`; others are skipped.
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let digest = trimmed.prefix(64)
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else { continue }
            var rest = trimmed.dropFirst(64)
            guard rest.first == " " || rest.first == "\t" else { continue }
            rest = rest.drop { $0 == " " || $0 == "\t" }
            if rest.first == "*" { rest = rest.dropFirst() }
            let name = String(rest)
            if !name.isEmpty, result[name] == nil { result[name] = digest.lowercased() }
        }
        return result
    }

    /// The listed digest for `name`, also when SHA256SUMS lists it with a folder such as `dist/`.
    public static func digest(for name: String, in text: String) -> String? {
        let entries = parse(text)
        return entries[name] ?? entries.first { ($0.key as NSString).lastPathComponent == name }?.value
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func verify(_ file: URL, named name: String, against text: String) throws {
        guard let expected = digest(for: name, in: text) else { throw UpdateError.checksumMissing(name) }
        guard try sha256(of: file) == expected else { throw UpdateError.checksumMismatch(name) }
    }
}

/// The `/bin/sh` program that swaps the app bundle after the running copy quits. Paths arrive as positional
/// arguments, never inside the script text: $1 the PID to wait for, $2 the verified new bundle, $3 the installed
/// bundle, $4 `1` to reopen it, $5 the staging folder to remove.
public enum UpdateSwap {
    public static let script = """
    trap '' HUP
    pid="$1"; new="$2"; target="$3"; reopen="$4"; staging="$5"
    aside="$(dirname "$target")/.$(basename "$target").replaced-$$"
    waited=0
    while kill -0 "$pid" 2>/dev/null; do
        waited=$((waited + 1))
        [ "$waited" -gt 600 ] && exit 1
        sleep 0.1
    done
    status=0
    if mv "$target" "$aside"; then
        if mv "$new" "$target"; then
            rm -rf "$aside"
        else
            mv "$aside" "$target"
            status=1
        fi
    else
        status=1
    fi
    [ -n "$staging" ] && rm -rf "$staging"
    [ "$reopen" = 1 ] && /usr/bin/open "$target"
    exit $status
    """

    public static func arguments(waitingFor pid: Int32, new: URL, target: URL, reopen: Bool, staging: URL?) -> [String] {
        ["-c", script, "macos-lens-update", String(pid), new.path, target.path, reopen ? "1" : "0", staging?.path ?? ""]
    }
}
