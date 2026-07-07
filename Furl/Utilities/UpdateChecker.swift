//
//  UpdateChecker.swift
//  Furl
//
//  The ONLY networking in the app: a user-initiated check of the latest
//  GitHub release. Fetches one version string, compares it to the running
//  version, and offers a link to the releases page. Nothing is downloaded
//  or executed, and nothing runs automatically — the check happens only
//  when the user clicks the button in the About pane.
//

import Foundation

enum UpdateChecker {
    enum Outcome {
        case upToDate
        case available(version: String, url: URL)
        case failed
    }

    private static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/julianbaker/Furl/releases/latest")!

    static func check() async -> Outcome {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = json["tag_name"] as? String,
            let releasePage = (json["html_url"] as? String).flatMap(URL.init(string:))
        else {
            return .failed
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return isNewer(latest, than: Constants.versionString)
            ? .available(version: latest, url: releasePage)
            : .upToDate
    }

    /// Numeric dotted-component comparison, so "1.0.10" beats "1.0.9".
    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let lhs = index < a.count ? a[index] : 0
            let rhs = index < b.count ? b[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }
}
