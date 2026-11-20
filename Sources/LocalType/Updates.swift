import AppKit

/// New versions come from the GitHub releases of the repository. LocalType only tells you and opens the release
/// page; it never downloads or installs anything by itself.
enum Updates {
    static let repo = "ramirobuisan/localtype"
    static var repoURL: URL { URL(string: "https://github.com/\(repo)")! }
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }

    struct Release { let version: String; let url: URL }
    enum Outcome { case upToDate, available(Release), failed(String) }

    /// Set when a check found a newer release (the menu-bar menu shows it).
    private(set) static var available: Release?

    static func check(_ done: @escaping (Outcome) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("LocalType/\(current)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let outcome: Outcome
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let err {
                outcome = .failed(err.localizedDescription)
            } else if status == 404 {
                outcome = .failed("No public releases found (the repository may be private or have no releases yet).")
            } else if status != 200 {
                outcome = .failed("GitHub answered with status \(status).")
            } else if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = obj["tag_name"] as? String, let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) {
                let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                outcome = isNewer(version, than: current) ? .available(Release(version: version, url: page)) : .upToDate
            } else {
                outcome = .failed("Couldn't read GitHub's answer.")
            }
            DispatchQueue.main.async {
                Settings.lastUpdateCheck = Date()
                if case .available(let r) = outcome { available = r } else if case .upToDate = outcome { available = nil }
                done(outcome)
            }
        }.resume()
    }

    /// At launch, at most once a day, if automatic checks are on.
    static func checkInBackgroundIfDue(_ found: @escaping () -> Void) {
        guard Settings.autoCheckUpdates, Date().timeIntervalSince(Settings.lastUpdateCheck) > 24 * 3600 else { return }
        check { if case .available = $0 { found() } }
    }

    /// Numeric comparison of dotted versions ("0.10.0" > "0.9.2").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// The model that suits this Mac best among the installed ones: a ~4B model is fast enough to keep up with typing
/// and good enough to be useful; tiny ones are too rough and big ones too slow.
func recommendedModel(_ list: [InstalledModel], backend: String) -> String? {
    let preferred = backend == "mlxserve" ? ["gemma-4-e4b", "qwen3.5-4b", "gemma-4-e2b"] : ["qwen2.5-3b", "llama-3.2-3b", "gemma-3-4b"]
    for p in preferred { if let m = list.first(where: { $0.name.lowercased().contains(p) }) { return m.name } }
    return list.filter { $0.size > 1_500_000_000 }.min { $0.size < $1.size }?.name
}
