import Foundation

/// Resolves the Claude Code transcript roots TokenScope scans: the default
/// `~/.claude/projects` plus any `ExtraClaudeProjectDirs` user-default entries
/// (sessions launched with `CLAUDE_CONFIG_DIR=<dir>` write to `<dir>/projects`).
enum ClaudeProjectRoots {
    static let defaultsKey = "ExtraClaudeProjectDirs"

    /// Default root first, then extras. `~` is expanded, paths are standardised,
    /// and relative/empty entries and duplicates are dropped. Existence is NOT
    /// checked here (a directory created later must start working); use `existing`.
    static func resolve(extra: [String], home: URL) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        func add(_ url: URL) {
            let std = url.standardizedFileURL
            if seen.insert(std.path).inserted { out.append(std) }
        }
        add(home.appendingPathComponent(".claude/projects"))
        for raw in extra {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let expanded = trimmed.hasPrefix("~")
                ? (trimmed as NSString).expandingTildeInPath : trimmed
            guard expanded.hasPrefix("/") else { continue }
            add(URL(fileURLWithPath: expanded, isDirectory: true))
        }
        return out
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
