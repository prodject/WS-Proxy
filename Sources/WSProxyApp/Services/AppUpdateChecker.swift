import Foundation

struct AppReleaseVersion: Comparable, Equatable {
    let marketing: [Int]
    let build: Int
    let attempt: Int
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue

        let cleaned = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = cleaned.hasPrefix("v") || cleaned.hasPrefix("V") ? String(cleaned.dropFirst()) : cleaned
        let components = withoutPrefix.components(separatedBy: "-build")

        if let marketingPart = components.first, !marketingPart.isEmpty {
            marketing = marketingPart.split(separator: ".").compactMap { Int($0) }
        } else {
            marketing = [0]
        }

        if components.count == 2 {
            let buildParts = components[1].components(separatedBy: "-a")
            build = Int(buildParts.first ?? "") ?? 0
            attempt = Int(buildParts.dropFirst().first ?? "") ?? 0
        } else {
            build = 0
            attempt = 0
        }
    }

    static func current(bundle: Bundle = .main) -> AppReleaseVersion {
        let marketingVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let buildNumber = bundle.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "0"
        return AppReleaseVersion(rawValue: "v\(marketingVersion)-build\(buildNumber)-a1")
    }

    static func < (lhs: AppReleaseVersion, rhs: AppReleaseVersion) -> Bool {
        let count = max(lhs.marketing.count, rhs.marketing.count)
        for index in 0..<count {
            let left = index < lhs.marketing.count ? lhs.marketing[index] : 0
            let right = index < rhs.marketing.count ? rhs.marketing[index] : 0
            if left != right {
                return left < right
            }
        }
        if lhs.build != rhs.build {
            return lhs.build < rhs.build
        }
        return lhs.attempt < rhs.attempt
    }
}

struct AppUpdateInfo: Equatable, Identifiable {
    let currentVersion: String
    let latestVersion: String
    let releasePageURL: URL
    let downloadURL: URL?

    var id: String { latestVersion }
}

enum AppUpdateStatus: Equatable {
    case idle
    case checking
    case upToDate(String)
    case updateAvailable(AppUpdateInfo)
    case failed(String)
}

final class AppUpdateChecker {
    private enum CacheKey {
        static let checkedAt = "wsproxy.update.checkedAt"
        static let etag = "wsproxy.update.etag"
        static let latestTag = "wsproxy.update.latestTag"
        static let releaseURL = "wsproxy.update.releaseURL"
        static let ipaURL = "wsproxy.update.ipaURL"
    }

    private let session: URLSession
    private let defaults: UserDefaults
    private let latestReleaseURL = URL(string: "https://api.github.com/repos/prodject/WS-Proxy/releases/latest")!
    private let fallbackReleasePageURL = URL(string: "https://github.com/prodject/WS-Proxy/releases/latest")!
    private let minimumCheckInterval: TimeInterval

    init(
        session: URLSession = .shared,
        defaults: UserDefaults = .standard,
        minimumCheckInterval: TimeInterval = 3600
    ) {
        self.session = session
        self.defaults = defaults
        self.minimumCheckInterval = minimumCheckInterval
    }

    func checkForUpdates(
        currentVersion: AppReleaseVersion,
        force: Bool = false
    ) async -> AppUpdateStatus {
        if !force, let cached = cachedStatus(for: currentVersion) {
            return cached
        }

        do {
            var request = URLRequest(url: latestReleaseURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("WSProxy-iOS-UpdateCheck", forHTTPHeaderField: "User-Agent")
            if let etag = defaults.string(forKey: CacheKey.etag), !etag.isEmpty {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed("Unexpected update server response")
            }

            if httpResponse.statusCode == 304 {
                defaults.set(Date().timeIntervalSince1970, forKey: CacheKey.checkedAt)
                return cachedStatus(for: currentVersion) ?? .upToDate(currentVersion.rawValue)
            }

            guard httpResponse.statusCode == 200 else {
                return await fallbackWebCheck(currentVersion: currentVersion, etag: httpResponse.value(forHTTPHeaderField: "ETag"))
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            persist(release: release, etag: httpResponse.value(forHTTPHeaderField: "ETag"))
            return makeStatus(from: release, currentVersion: currentVersion)
        } catch {
            let fallbackStatus = await fallbackWebCheck(currentVersion: currentVersion, etag: nil)
            if case .failed = fallbackStatus {
                return .failed(error.localizedDescription)
            }
            return fallbackStatus
        }
    }

    private func fallbackWebCheck(
        currentVersion: AppReleaseVersion,
        etag: String?
    ) async -> AppUpdateStatus {
        do {
            var request = URLRequest(url: fallbackReleasePageURL)
            request.setValue("WSProxy-iOS-UpdateCheck", forHTTPHeaderField: "User-Agent")
            if let etag, !etag.isEmpty {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failed("Unexpected update page response")
            }
            guard (200...299).contains(httpResponse.statusCode), let finalURL = httpResponse.url else {
                return .failed("Update check failed with HTTP \(httpResponse.statusCode)")
            }

            let tagName = extractTagName(from: finalURL)
            guard !tagName.isEmpty else {
                return .failed("Unable to parse latest release")
            }

            let html = String(decoding: data, as: UTF8.self)
            let ipaURL = extractIPAURL(fromHTML: html)
            let release = GitHubRelease(
                tagName: tagName,
                htmlURL: finalURL,
                assets: ipaURL.map { [GitHubRelease.Asset(name: $0.lastPathComponent, browserDownloadURL: $0)] } ?? []
            )
            persist(release: release, etag: httpResponse.value(forHTTPHeaderField: "ETag"))
            return makeStatus(from: release, currentVersion: currentVersion)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func cachedStatus(for currentVersion: AppReleaseVersion) -> AppUpdateStatus? {
        let checkedAt = defaults.double(forKey: CacheKey.checkedAt)
        guard checkedAt > 0 else { return nil }
        guard Date().timeIntervalSince1970 - checkedAt < minimumCheckInterval else {
            return nil
        }

        guard let latestTag = defaults.string(forKey: CacheKey.latestTag), !latestTag.isEmpty else {
            return nil
        }

        let releaseURL = URL(string: defaults.string(forKey: CacheKey.releaseURL) ?? "") ?? fallbackReleasePageURL
        let ipaURL = URL(string: defaults.string(forKey: CacheKey.ipaURL) ?? "")
        let info = AppUpdateInfo(
            currentVersion: currentVersion.rawValue,
            latestVersion: latestTag,
            releasePageURL: releaseURL,
            downloadURL: ipaURL
        )
        return AppReleaseVersion(rawValue: latestTag) > currentVersion ? .updateAvailable(info) : .upToDate(currentVersion.rawValue)
    }

    private func persist(release: GitHubRelease, etag: String?) {
        defaults.set(Date().timeIntervalSince1970, forKey: CacheKey.checkedAt)
        defaults.set(release.tagName, forKey: CacheKey.latestTag)
        defaults.set(release.htmlURL.absoluteString, forKey: CacheKey.releaseURL)
        defaults.set(release.assets.first(where: { $0.isIPA })?.browserDownloadURL.absoluteString, forKey: CacheKey.ipaURL)
        if let etag, !etag.isEmpty {
            defaults.set(etag, forKey: CacheKey.etag)
        }
    }

    private func makeStatus(from release: GitHubRelease, currentVersion: AppReleaseVersion) -> AppUpdateStatus {
        let latestVersion = AppReleaseVersion(rawValue: release.tagName)
        guard latestVersion > currentVersion else {
            return .upToDate(currentVersion.rawValue)
        }

        let info = AppUpdateInfo(
            currentVersion: currentVersion.rawValue,
            latestVersion: release.tagName,
            releasePageURL: release.htmlURL,
            downloadURL: release.assets.first(where: { $0.isIPA })?.browserDownloadURL
        )
        return .updateAvailable(info)
    }

    private func extractTagName(from url: URL) -> String {
        let components = url.pathComponents
        guard let tagIndex = components.firstIndex(of: "tag"), tagIndex + 1 < components.count else {
            return ""
        }
        return components[tagIndex + 1]
    }

    private func extractIPAURL(fromHTML html: String) -> URL? {
        let pattern = #"https://github\.com/[^"]+\.ipa"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let matchRange = Range(match.range, in: html) else {
            return nil
        }
        return URL(string: String(html[matchRange]))
    }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL

        var isIPA: Bool {
            name.lowercased().hasSuffix(".ipa")
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }

        init(name: String, browserDownloadURL: URL) {
            self.name = name
            self.browserDownloadURL = browserDownloadURL
        }
    }

    let tagName: String
    let htmlURL: URL
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }

    init(tagName: String, htmlURL: URL, assets: [Asset]) {
        self.tagName = tagName
        self.htmlURL = htmlURL
        self.assets = assets
    }
}
