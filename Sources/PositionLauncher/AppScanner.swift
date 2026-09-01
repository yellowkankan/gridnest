import Foundation

enum AppScanner {
    static func scan() -> [AppInfo] {
        let fm = FileManager.default
        let roots: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/opt/homebrew/Caskroom"),
            URL(fileURLWithPath: "/usr/local/Caskroom"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var seen = Set<String>()
        var result: [AppInfo] = []
        for root in roots where fm.fileExists(atPath: root.path) {
            collect(root, into: &result, seen: &seen, depth: 0)
        }
        return result.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func collect(_ dir: URL, into result: inout [AppInfo],
                                seen: inout Set<String>, depth: Int) {
        guard depth <= 4 else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in items {
            if url.pathExtension == "app" {
                let values = try? url.resourceValues(forKeys: [.isAliasFileKey, .isSymbolicLinkKey])
                // Finder aliases and login helpers are launch infrastructure,
                // not user-facing applications. Their bundles commonly carry
                // only the generic blueprint icon.
                guard values?.isAliasFile != true, values?.isSymbolicLink != true else { continue }
                let key = url.lastPathComponent
                guard seen.insert(key).inserted else { continue }
                var name = fm.displayName(atPath: url.path)
                if name.hasSuffix(".app") { name.removeLast(4) }
                let normalized = name.replacingOccurrences(of: " ", with: "").lowercased()
                guard !normalized.contains("loginhelper"), !normalized.hasSuffix("helper") else { continue }
                result.append(AppInfo(id: url.path, name: name))
            } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                collect(url, into: &result, seen: &seen, depth: depth + 1)
            }
        }
    }
}
