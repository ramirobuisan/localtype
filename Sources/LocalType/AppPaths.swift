import Foundation

/// On-disk locations, plus a one-time move of data written by builds that still used the old name.
enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LocalType", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Moves only files this app created (history.json, Models/*.gguf) out of the pre-rename folder,
    /// and copies preferences from the pre-rename defaults domain. Safe to call on every launch.
    static func migrateLegacyData() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("Cotypist", isDirectory: true)
        if fm.fileExists(atPath: old.path) {
            let oldHistory = old.appendingPathComponent("history.json")
            let newHistory = support.appendingPathComponent("history.json")
            if fm.fileExists(atPath: oldHistory.path), !fm.fileExists(atPath: newHistory.path) {
                try? fm.moveItem(at: oldHistory, to: newHistory)
            }
            let oldModels = old.appendingPathComponent("Models", isDirectory: true)
            let newModels = support.appendingPathComponent("Models", isDirectory: true)
            try? fm.createDirectory(at: newModels, withIntermediateDirectories: true)
            for f in (try? fm.contentsOfDirectory(at: oldModels, includingPropertiesForKeys: nil)) ?? []
            where f.pathExtension.lowercased() == "gguf" {
                let dest = newModels.appendingPathComponent(f.lastPathComponent)
                if !fm.fileExists(atPath: dest.path) { try? fm.moveItem(at: f, to: dest) }
            }
            for dir in [oldModels, old] where ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? ["x"]).isEmpty {
                try? fm.removeItem(at: dir)
            }
        }

        let d = UserDefaults.standard
        if !d.bool(forKey: "migratedLegacyDefaults") {
            if let legacy = UserDefaults(suiteName: "local.cotypist.clone")?.persistentDomain(forName: "local.cotypist.clone") {
                for (k, v) in legacy where d.object(forKey: k) == nil && !k.hasPrefix("NS") { d.set(v, forKey: k) }
            }
            d.set(true, forKey: "migratedLegacyDefaults")
        }
    }
}
