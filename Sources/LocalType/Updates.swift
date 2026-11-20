import AppKit
import CryptoKit
import Security

/// New versions come from the GitHub releases of the repository. LocalType checks for them, shows what's new and,
/// when you say so, downloads, verifies and installs the update, then relaunches.
enum Updates {
    static let repo = "ramirobuisan/localtype"
    static var repoURL: URL { URL(string: "https://github.com/\(repo)")! }
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }

    struct Release {
        let version: String
        let url: URL            // release page
        let notes: String       // release notes (Markdown)
        let zip: URL?           // the app download
        let sha256: String?     // expected SHA-256 of the zip
    }
    enum Outcome { case upToDate, available(Release), failed(String) }

    /// Set when a check found a newer release (the menu-bar menu shows it).
    private(set) static var available: Release?

    static func check(_ done: @escaping (Outcome) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("LocalType/\(current)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let finish = { (o: Outcome) in
                DispatchQueue.main.async {
                    Settings.lastUpdateCheck = Date()
                    if case .available(let r) = o { available = r } else if case .upToDate = o { available = nil }
                    done(o)
                }
            }
            if let err { return finish(.failed(err.localizedDescription)) }
            if status == 404 { return finish(.failed("No public releases found (the repository may be private or have no releases yet).")) }
            guard status == 200, let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String, let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) else {
                return finish(.failed(status == 200 ? "Couldn't read GitHub's answer." : "GitHub answered with status \(status)."))
            }
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard isNewer(version, than: current) else { return finish(.upToDate) }
            let notes = obj["body"] as? String ?? ""
            let assets = obj["assets"] as? [[String: Any]] ?? []
            func asset(_ suffix: String) -> URL? {
                assets.first { ($0["name"] as? String)?.hasSuffix(suffix) == true }
                    .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
            }
            let zip = asset(".zip")
            // The checksum comes from a "<zip>.sha256" asset, or else from the release notes.
            let fromNotes = notes.range(of: #"\b[0-9a-f]{64}\b"#, options: .regularExpression).map { String(notes[$0]) }
            if let shaURL = asset(".zip.sha256") {
                URLSession.shared.dataTask(with: shaURL) { d, _, _ in
                    let text = d.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    let s = text.range(of: #"[0-9a-f]{64}"#, options: .regularExpression).map { String(text[$0]) }
                    finish(.available(Release(version: version, url: page, notes: notes, zip: zip, sha256: s ?? fromNotes)))
                }.resume()
            } else {
                finish(.available(Release(version: version, url: page, notes: notes, zip: zip, sha256: fromNotes)))
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

/// Downloads, verifies and installs an update, then relaunches LocalType.
///
/// Safety: the zip must match the published SHA-256; the app inside must be LocalType (same bundle ID) at the
/// expected version with a valid signature. Before installing, the new copy is re-signed with the certificate the
/// running copy was signed with, when this Mac has it, so macOS keeps the Accessibility and Screen Recording
/// permissions (they're tied to the signature). Copies signed ad hoc stay ad hoc.
final class Updater: NSObject, URLSessionDownloadDelegate {
    enum Step { case downloading(Double?), verifying, installing, relaunching, failed(String) }

    private var session: URLSession!
    private var onStep: ((Step) -> Void)?
    private var release: Updates.Release?
    private var task: URLSessionDownloadTask?

    func install(_ release: Updates.Release, onStep: @escaping (Step) -> Void) {
        self.release = release
        self.onStep = onStep
        guard let zip = release.zip else { return fail("This release has no app download attached.") }
        guard release.sha256 != nil else { return fail("This release doesn't publish a checksum, so it can't be verified.") }
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
        task = session.downloadTask(with: zip)
        task?.resume()
        onStep(.downloading(nil))
    }

    func cancel() { task?.cancel(); session?.invalidateAndCancel() }

    private func fail(_ why: String) { DispatchQueue.main.async { self.onStep?(.failed(why)) } }
    private func step(_ s: Step) { DispatchQueue.main.async { self.onStep?(s) } }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        onStep?(.downloading(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled { fail("Download failed: \(error.localizedDescription)") }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns: move it somewhere of our own first.
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("LocalType-update-\(UUID().uuidString)")
        let zip = work.appendingPathComponent("update.zip")
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: zip)
        } catch { return fail("Couldn't save the download: \(error.localizedDescription)") }
        session.finishTasksAndInvalidate()
        onStep?(.verifying)
        DispatchQueue.global(qos: .userInitiated).async { self.finish(zip: zip, work: work) }
    }

    // MARK: Verify and install (background queue)

    private func finish(zip: URL, work: URL) {
        guard let release else { return }
        defer { if installedApp == nil { try? FileManager.default.removeItem(at: work) } }

        // 1. Checksum
        guard let data = try? Data(contentsOf: zip, options: .mappedIfSafe) else { return fail("Couldn't read the download.") }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == release.sha256?.lowercased() else { return fail("The download doesn't match the published checksum, so it wasn't installed.") }

        // 2. Unpack and check what's inside
        let unpacked = work.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0,
              let app = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }),
              let info = Bundle(url: app)?.infoDictionary else { return fail("The download doesn't contain the app.") }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else { return fail("The download isn't LocalType.") }
        guard info["CFBundleShortVersionString"] as? String == release.version else { return fail("The download has an unexpected version.") }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) == 0 else { return fail("The download's signature is invalid.") }

        // 3. Sign it like the running copy, so macOS keeps this Mac's permissions.
        step(.installing)
        if let identity = Updater.runningSigningIdentity() {
            if run("/usr/bin/codesign", ["--force", "--deep", "--sign", identity, app.path]) != 0 {
                NSLog("LocalType update: re-signing with the current certificate failed; keeping the release signature")
            }
        }

        // 4. Replace this copy and relaunch.
        let target = Bundle.main.bundleURL
        do {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: app, backupItemName: nil, options: [])
        } catch {
            return fail("Couldn't replace \(target.path): \(error.localizedDescription)")
        }
        installedApp = target
        try? FileManager.default.removeItem(at: work)
        step(.relaunching)
        DispatchQueue.main.async { Updater.relaunch(target) }
    }

    private var installedApp: URL?

    /// SHA-1 of the certificate this copy is signed with, if it's a real certificate (not ad hoc) whose private key
    /// is in this Mac's keychain; nil otherwise.
    static func runningSigningIdentity() -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let leaf = (dict[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        else { return nil }
        let sha1 = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02X", $0) }.joined()
        // Only if this Mac can actually sign with it.
        let out = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-identity", "-v", "-p", "codesigning"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let list = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return list.uppercased().contains(sha1) ? sha1 : nil
    }

    /// Waits for this process to exit, then opens the (new) app.
    static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    private func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// The model that suits this Mac best among the installed ones: a ~4B model is fast enough to keep up with typing
/// and good enough to be useful; tiny ones are too rough and big ones too slow.
func recommendedModel(_ list: [InstalledModel], backend: String) -> String? {
    let preferred = backend == "mlxserve" ? ["gemma-4-e4b", "qwen3.5-4b", "gemma-4-e2b"] : ["qwen2.5-3b", "llama-3.2-3b", "gemma-3-4b"]
    for p in preferred { if let m = list.first(where: { $0.name.lowercased().contains(p) }) { return m.name } }
    return list.filter { $0.size > 1_500_000_000 }.min { $0.size < $1.size }?.name
}
