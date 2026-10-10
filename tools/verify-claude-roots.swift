import Foundation

/// Framework-free checks for Claude Code transcript root resolution. Run with:
/// swiftc Sources/TokenScope/ClaudeProjectRoots.swift tools/verify-claude-roots.swift -o /tmp/tokenscope-roots-checks && /tmp/tokenscope-roots-checks
@main
struct RootChecks {
    static func expect(_ ok: Bool, _ msg: String) {
        if !ok { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); exit(1) }
    }

    static func main() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("ts-roots-\(UUID().uuidString)")
        let home = tmp.appendingPathComponent("home")
        try fm.createDirectory(at: home.appendingPathComponent(".claude/projects"), withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent("lean/projects"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let h = home.resolvingSymlinksInPath().path

        let none = ClaudeProjectRoots.resolve(extra: [], home: home).map(\.path)
        expect(none == ["\(h)/.claude/projects"], "default root only when no extras")

        let tilde = ClaudeProjectRoots.resolve(extra: ["~/x/projects"], home: home).map(\.path)
        expect(tilde.count == 2 && tilde[1] == NSHomeDirectory() + "/x/projects", "~ expands")

        let dup = ClaudeProjectRoots.resolve(
            extra: ["\(h)/lean/projects", "\(h)/lean/projects/", "\(h)/lean/../lean/projects",
                    "\(h)/.claude/projects", "", "relative/dir"], home: home).map(\.path)
        expect(dup == ["\(h)/.claude/projects", "\(h)/lean/projects"],
               "dedups after standardisation, drops default dup, empty and relative: \(dup)")

        let ex = ClaudeProjectRoots.existing(
            extra: ["\(h)/lean/projects", "\(h)/missing/projects"], home: home).map(\.path)
        expect(ex == ["\(h)/.claude/projects", "\(h)/lean/projects"], "missing dirs skipped: \(ex)")

        try fm.createDirectory(at: home.appendingPathComponent("missing/projects"), withIntermediateDirectories: true)
        let later = ClaudeProjectRoots.existing(
            extra: ["\(h)/missing/projects"], home: home).map(\.path)
        expect(later.contains("\(h)/missing/projects"), "dir created later is picked up")

        // symlinked root (last component a symlink) resolves to its target
        try fm.createDirectory(at: tmp.appendingPathComponent("real/projects"), withIntermediateDirectories: true)
        let link = tmp.appendingPathComponent("linkroot")
        try fm.createSymbolicLink(at: link, withDestinationURL: tmp.appendingPathComponent("real/projects"))
        let sym = ClaudeProjectRoots.existing(extra: [link.path], home: home).map(\.path)
        expect(sym.contains(tmp.resolvingSymlinksInPath().path + "/real/projects"), "symlinked root resolved: \(sym)")

        // config dir given instead of its projects subdir -> <dir>/projects
        let cfg = ClaudeProjectRoots.resolve(extra: ["\(h)/lean"], home: home).map(\.path)
        expect(cfg == ["\(h)/.claude/projects", "\(h)/lean/projects"], "config dir maps to projects: \(cfg)")
        let nosub = ClaudeProjectRoots.resolve(extra: ["\(h)/plain"], home: home).map(\.path)
        expect(nosub.last == "\(h)/plain", "entry without projects subdir kept as-is: \(nosub)")

        // broad roots rejected
        let broad = ClaudeProjectRoots.resolveDetailed(extra: ["/", h, "\(h)/"], home: home)
        expect(broad.roots.map(\.path) == ["\(h)/.claude/projects"] && broad.rejected.count == 3,
               "/ and $HOME rejected: \(broad)")

        // tolerant parsing
        expect(ClaudeProjectRoots.entries(from: " /a \n") == ["/a"], "bare string, trimmed")
        expect(ClaudeProjectRoots.entries(from: ["/a", 3, "", " /b "] as [Any]) == ["/a", "/b"], "array, non-strings dropped")
        expect(ClaudeProjectRoots.entries(from: nil).isEmpty && ClaudeProjectRoots.entries(from: 5).isEmpty, "nil/other ignored")

        print("claude-roots checks passed")
    }
}
