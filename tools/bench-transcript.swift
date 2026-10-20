import Foundation

/// Launch-replay benchmark for the Claude transcript read + parse path
/// (framework-free, read-only). Times a full parse of every *.jsonl under a
/// directory (recursive) with the SAME read loop the watcher uses and prints wall
/// time, lines/s and a result checksum (so before/after runs can be compared for
/// identical output). Peak RSS comes from /usr/bin/time -l:
///
///   swiftc -O Sources/TokenScope/Models.swift Sources/TokenScope/EventReconciler.swift \
///     Sources/TokenScope/ClaudeTranscriptParser.swift Sources/TokenScope/TranscriptIO.swift \
///     tools/bench-transcript.swift -o /tmp/tokenscope-bench
///   /usr/bin/time -l /tmp/tokenscope-bench ~/.claude/projects
///
/// `-D OLDREAD` builds the pre-optimization loop (readToEnd + Data.firstIndex +
/// Data.range markers, no chunking) for baseline measurement; it needs a
/// TranscriptIO-free build (the file is not compiled in that variant).
/// BENCH_SINCE_DAYS=N limits to files modified in the last N days (default: all).
@main
struct TranscriptBench {
    static func main() {
        let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
            : NSString(string: "~/.claude/projects").expandingTildeInPath
        let fm = FileManager.default
        let sinceDays = Double(ProcessInfo.processInfo.environment["BENCH_SINCE_DAYS"] ?? "") ?? 0
        let minMtime = sinceDays > 0 ? Date().addingTimeInterval(-sinceDays * 86400) : Date.distantPast
        // BENCH_QUIET_MIN=N skips files written in the last N minutes so repeated runs
        // over the live corpus see identical bytes (checksums comparable).
        let quietMin = Double(ProcessInfo.processInfo.environment["BENCH_QUIET_MIN"] ?? "") ?? 0
        let maxMtime = Date().addingTimeInterval(-quietMin * 60)
        var files: [(path: String, mtime: Date)] = []
        if let en = fm.enumerator(atPath: dir) {
            for case let rel as String in en where rel.hasSuffix(".jsonl") {
                let path = dir + "/" + rel
                let mt = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast
                if mt >= minMtime && mt <= maxMtime { files.append((path, mt)) }
            }
        }
        files.sort { $0.path < $1.path }

        #if !OLDREAD
        let assistantN = TranscriptIO.Needle("\"assistant\""), titleN = TranscriptIO.Needle("\"ai-title\"")
        let summaryN = TranscriptIO.Needle("\"type\":\"summary\""), userN = TranscriptIO.Needle("\"type\":\"user\"")
        #endif
        var parser = ClaudeTranscriptParser()
        var best: [String: UsageEvent] = [:]
        var lines = 0, assistantLines = 0, metaHits = 0, bytes: UInt64 = 0
        var maxLine = 0
        let t0 = Date()
        for f in files {
            let session = ((f.path as NSString).lastPathComponent as NSString).deletingPathExtension
            let mt = f.mtime
            func handle(_ line: Data) {
                lines += 1
                maxLine = max(maxLine, line.count)
                #if OLDREAD
                guard line.range(of: Data("\"assistant\"".utf8)) != nil else {
                    if line.range(of: Data("\"ai-title\"".utf8)) != nil
                        || line.range(of: Data("\"type\":\"summary\"".utf8)) != nil
                        || line.range(of: Data("\"type\":\"user\"".utf8)) != nil { metaHits += 1 }
                    return
                }
                #else
                let isAssistant = line.withUnsafeBytes { TranscriptIO.contains($0, assistantN) }
                guard isAssistant else {
                    let m = line.withUnsafeBytes {
                        ($0.count <= 16 * 1024 && (TranscriptIO.contains($0, titleN) || TranscriptIO.contains($0, summaryN)))
                            || TranscriptIO.contains($0, userN)
                    }
                    if m { metaHits += 1 }
                    return
                }
                #endif
                assistantLines += 1
                for o in parser.parse(line, fileKey: f.path, fileSession: session, mtime: { mt }) {
                    best[o.dedupKey] = best[o.dedupKey].map { EventReconciler.preferred($0, o.event) } ?? o.event
                }
            }
            #if OLDREAD
            guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: f.path)),
                  let data = try? fh.readToEnd(), !data.isEmpty else { continue }
            bytes += UInt64(data.count)
            var start = data.startIndex
            while let nl = data[start...].firstIndex(of: 0x0A) {
                let line = data[start..<nl]
                start = nl + 1
                if !line.isEmpty { handle(Data(line)) }
            }
            #else
            autoreleasepool {
                let end = TranscriptIO.forEachLine(path: f.path, from: 0) { raw, _ in
                    handle(TranscriptIO.data(raw))
                }
                bytes += end
            }
            #endif
        }
        let secs = Date().timeIntervalSince(t0)
        var out = 0, inp = 0, cr = 0, cc = 0, est = 0
        var tsSum = 0
        for e in best.values {
            out += e.outputTokens; inp += e.inputTokens; cr += e.cacheReadTokens; cc += e.cacheCreationTokens
            if e.tokenAccuracy == .estimated { est += 1 }
            tsSum &+= Int((e.timestamp.timeIntervalSince1970 * 1000).rounded())
        }
        print("files \(files.count) bytes \(bytes / 1_048_576) MB lines \(lines) assistant \(assistantLines) meta-hits \(metaHits) max-line \(maxLine)")
        print(String(format: "wall %.2fs  %.0f lines/s  %.0f MB/s", secs, Double(lines) / secs, Double(bytes) / 1_048_576 / secs))
        print("checksum events \(best.count) estimated \(est) in \(inp) out \(out) cacheRead \(cr) cacheCreate \(cc) tsMsSum \(tsSum)")
    }
}
