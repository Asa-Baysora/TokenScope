import Foundation

/// Resolves the Claude transcript roots TokenScope scans, in order: the default
/// `~/.claude/projects`, the built-in Claude Cowork / Desktop agent-session root
/// (`~/Library/Application Support/Claude/local-agent-mode-sessions`, when it
/// exists and `IncludeCoworkSessions` is not false), then any
/// `ExtraClaudeProjectDirs` user-default entries (sessions launched with
/// `CLAUDE_CONFIG_DIR=<dir>` write to `<dir>/projects`).
enum ClaudeProjectRoots {
    static let defaultsKey = "ExtraClaudeProjectDirs"
    /// Bool opt-out for the built-in Cowork root; absent means included.
    static let includeCoworkKey = "IncludeCoworkSessions"

    enum Kind: String {
        case primary, cowork, extra
        /// Short name for UI / logs.
        var label: String {
            switch self {
            case .primary: return "Claude Code"
            case .cowork: return "Cowork"
            case .extra: return "Extra"
            }
        }
    }

    /// Cowork root relative to `home`.
    static func coworkRoot(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions",
                                    isDirectory: true)
    }

    /// Reads the opt-out; anything but an explicit false/0/"NO" keeps Cowork on.
    static func coworkEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard let v = defaults.object(forKey: includeCoworkKey) else { return true }
        if let b = v as? Bool { return b }
        if let s = v as? String { return !["no", "false", "0"].contains(s.lowercased()) }
        return true
    }

    /// Transcripts under a root that must not be replayed. Cowork `audit.jsonl`
    /// files carry assistant/usage lines that duplicate the sibling session and
    /// `subagents/` transcripts (same message.id, but no `requestId`, so the
    /// parser's `id:requestId` dedup key would not match) and include streaming
    /// partials. The watcher must skip them.
    static func isIgnoredTranscript(_ url: URL) -> Bool {
        url.lastPathComponent == "audit.jsonl"
    }

    /// Tolerant read of the raw defaults value: an array (non-strings ignored)
    /// or a bare String. Entries are trimmed of whitespace and newlines.
    static func entries(from value: Any?) -> [String] {
        let raw: [String]
        if let s = value as? String { raw = [s] }
        else if let a = value as? [Any] { raw = a.compactMap { $0 as? String } }
        else { raw = [] }
        return raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Default root first, then the Cowork root (when `includeCowork`), then extras. `~` is expanded, symlinks resolved, paths
    /// standardised and deduped; relative entries and `/` / `$HOME` are rejected
    /// (reported in `rejected`). An entry not ending in `projects` whose
    /// `<entry>/projects` directory exists is replaced by it (a common mistake is
    /// pointing at CLAUDE_CONFIG_DIR itself). Existence of the final root is NOT
    /// checked here (a directory created later must start working); see `existing`.
    static func resolveDetailed(extra: [String], home: URL,
                                includeCowork: Bool = ClaudeProjectRoots.coworkEnabled(),
                                fileManager fm: FileManager = .default)
        -> (roots: [URL], rejected: [String], kinds: [String: Kind]) {
        var seen = Set<String>()
        var out: [URL] = []
        var rejected: [String] = []
        var kinds: [String: Kind] = [:]
        func norm(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
        func add(_ url: URL, _ kind: Kind) {
            let n = norm(url)
            if seen.insert(n.path).inserted { out.append(n); kinds[n.path] = kind }
        }
        let homePath = norm(home).path
        add(home.appendingPathComponent(".claude/projects"), .primary)
        if includeCowork {
            // Only when present now; a root created later is picked up by `existing`.
            let c = coworkRoot(home: home)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c.path, isDirectory: &isDir), isDir.boolValue { add(c, .cowork) }
        }
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
            add(url, .extra)
        }
        return (out, rejected, kinds)
    }

    static func resolve(extra: [String], home: URL,
                        includeCowork: Bool = ClaudeProjectRoots.coworkEnabled()) -> [URL] {
        resolveDetailed(extra: extra, home: home, includeCowork: includeCowork).roots
    }

    /// `resolve` filtered to directories that currently exist; missing or
    /// unreadable roots are skipped silently and re-checked on the next call.
    static func existing(extra: [String], home: URL,
                         includeCowork: Bool = ClaudeProjectRoots.coworkEnabled(),
                         fileManager fm: FileManager = .default) -> [URL] {
        resolve(extra: extra, home: home, includeCowork: includeCowork).filter {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
                && fm.isReadableFile(atPath: $0.path)
        }
    }
}
