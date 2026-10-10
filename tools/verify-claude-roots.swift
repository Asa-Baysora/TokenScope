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
        let h = home.standardizedFileURL.path

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

        print("claude-roots checks passed")
    }
}
