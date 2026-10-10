import Foundation

/// Resolves the Claude Code transcript roots TokenScope scans: the default
/// `~/.claude/projects` plus any `ExtraClaudeProjectDirs` user-default entries
/// (sessions launched with `CLAUDE_CONFIG_DIR=<dir>` write to `<dir>/projects`).
enum ClaudeProjectRoots {
    static let defaultsKey = "ExtraClaudeProjectDirs"

    /// Tolerant read of the raw defaults value: an array (non-strings ignored)
    /// or a bare String. Entries are trimmed of whitespace and newlines.
    static func entries(from value: Any?) -> [String] {
        let raw: [String]
        if let s = value as? String { raw = [s] }
        else if let a = value as? [Any] { raw = a.compactMap { $0 as? String } }
        else { raw = [] }
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Default root first, then extras. `~` is expanded, symlinks resolved, paths
    /// standardised and deduped; relative entries and `/` / `$HOME` are rejected
    /// (reported in `rejected`). An entry not ending in `projects` whose
    /// `<entry>/projects` directory exists is replaced by it (a common mistake is
    /// pointing at CLAUDE_CONFIG_DIR itself). Existence of the final root is NOT
    /// checked here (a directory created later must start working); see `existing`.
    static func resolveDetailed(extra: [String], home: URL,
                                fileManager fm: FileManager = .default)
        -> (roots: [URL], rejected: [String]) {
        var seen = Set<String>()
        var out: [URL] = []
        var rejected: [String] = []
        func norm(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
        func add(_ url: URL) {
            let n = norm(url)
            if seen.insert(n.path).inserted { out.append(n) }
        }
        let homePath = norm(home).path
        add(home.appendingPathComponent(".claude/projects"))
        for entry in extra {
            let expanded = entry.hasPrefix("~") ? (entry as NSString).expandingTildeInPath : entry
            guard expanded.hasPrefix("/") else { rejected.append(entry); continue }
            var url = URL(fileURLWithPath: expanded, isDirectory: true)
            let n = norm(url)
            if n.path == "/" || n.path == homePath { rejected.append(entry); continue }
            if n.lastPathComponent != "projects" {
                let sub = n.appendingPathComponent("projects", isDirectory: true)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue { url = sub }
            }
            add(url)
        }
        return (out, rejected)
    }

    static func resolve(extra: [String], home: URL) -> [URL] {
        resolveDetailed(extra: extra, home: home).roots
    }

    /// `resolve` filtered to directories that currently exist; missing or
    /// unreadable roots are skipped silently and re-checked on the next call.
    static func existing(extra: [String], home: URL,
                         fileManager fm: FileManager = .default) -> [URL] {
        resolve(extra: extra, home: home).filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
                && fm.isReadableFile(atPath: $0.path)
        }
    }
}
