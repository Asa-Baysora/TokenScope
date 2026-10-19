import Foundation

/// Framework-free checks for Claude transcript accuracy rules. Run with:
/// swiftc Sources/TokenScope/Models.swift Sources/TokenScope/EventReconciler.swift Sources/TokenScope/ClaudeTranscriptParser.swift tools/verify-transcript.swift -o /tmp/tokenscope-transcript-checks && /tmp/tokenscope-transcript-checks
/// Corpus sanity run (read-only, top-level *.jsonl of one directory; CORPUS_RECURSIVE=1 walks all):
///   /tmp/tokenscope-transcript-checks --corpus ~/.claude/projects/-Users-asalaws
@main
struct TranscriptChecks {
    static func expect(_ ok: Bool, _ msg: String) {
        if !ok { FileHandle.standardError.write(Data("FAIL: \(msg)\n".utf8)); exit(1) }
    }

    static func json(_ o: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: o)
    }

    static func line(id: String, req: String = "req_1", ts: String?, block: [String: Any],
                     stop: String? = nil, out: Int = 6, iterations: [[String: Any]]? = nil,
                     model: String = "claude-opus-4-7") -> Data {
        var usage: [String: Any] = ["input_tokens": 100, "output_tokens": out,
                                    "cache_read_input_tokens": 5000, "cache_creation_input_tokens": 200]
        if let iterations { usage["iterations"] = iterations }
        var msg: [String: Any] = ["id": id, "model": model, "content": [block], "usage": usage]
        msg["stop_reason"] = stop as Any? ?? NSNull()
        var o: [String: Any] = ["type": "assistant", "sessionId": "s1", "requestId": req,
                                "cwd": "/tmp/proj", "message": msg]
        if let ts { o["timestamp"] = ts }
        return json(o)
    }

    static func main() throws {
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--corpus" {
            corpus(CommandLine.arguments[2]); return
        }
        var p = ClaudeTranscriptParser()
        let mt = { Date(timeIntervalSince1970: 1_000) }
        let t1 = "2026-10-12T19:06:42.476Z", t2 = "2026-10-12T19:06:43.204Z", t3 = "2026-10-12T19:06:55.001Z"

        // 1. Unfinalized tool_use message across 3 lines (one block per line).
        let text = String(repeating: "a", count: 152)
        let input: [String: Any] = ["command": String(repeating: "x", count: 2000)]
        let inputChars = try JSONSerialization.data(withJSONObject: input,
                                                    options: [.withoutEscapingSlashes]).count
        let l1 = p.parse(line(id: "m1", ts: t1, block: ["type": "thinking", "thinking": "", "signature": "zz"]),
                         fileKey: "f", fileSession: "fs", mtime: mt)
        let l2 = p.parse(line(id: "m1", ts: t2, block: ["type": "text", "text": text]),
                         fileKey: "f", fileSession: "fs", mtime: mt)
        let l3 = p.parse(line(id: "m1", ts: t3, block: ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": input]),
                         fileKey: "f", fileSession: "fs", mtime: mt)
        // a repeated identical block line must not double-count
        let l3b = p.parse(line(id: "m1", ts: t3, block: ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": input]),
                          fileKey: "f", fileSession: "fs", mtime: mt)
        expect(l1.count == 1 && l1[0].event.tokenAccuracy == .estimated, "unfinalized line is estimated")
        expect(l1[0].event.outputTokens == 6, "tiny content keeps observed output")
        let want = (152 + inputChars + 3) / 4
        expect(l2[0].event.outputTokens == (152 + 3) / 4, "text accumulates: \(l2[0].event.outputTokens)")
        expect(l3[0].event.outputTokens == want && want > 500, "3rd line = ceil(chars/4)=\(want), got \(l3[0].event.outputTokens)")
        expect(l3b[0].event.outputTokens == want, "repeated block not double-counted")
        expect(l3[0].event.inputTokens == 100 && l3[0].event.cacheReadTokens == 5000, "input/cache untouched")
        expect(ClaudeTranscriptParser.charsPerToken == 4, "ratio constant")
        let best = EventReconciler.preferred(EventReconciler.preferred(l1[0].event, l3[0].event), l2[0].event)
        expect(best.outputTokens == want, "largest estimate wins among estimates")

        // 2. Later finalized line replaces the estimate, even with a smaller token sum.
        let fin = p.parse(line(id: "m1", ts: "2026-10-12T19:06:56.000Z", block: ["type": "text", "text": "ok"],
                               stop: "tool_use", out: 7), fileKey: "f", fileSession: "fs", mtime: mt)
        expect(fin[0].event.tokenAccuracy == .exact && fin[0].event.outputTokens == 7, "finalized is exact")
        expect(fin[0].dedupKey == l3[0].dedupKey, "same dedup key")
        expect(EventReconciler.preferred(l3[0].event, fin[0].event).id == fin[0].event.id, "exact replaces estimate")
        expect(EventReconciler.preferred(fin[0].event, l3[0].event).id == fin[0].event.id, "estimate never downgrades exact")

        // 3. Iterations: advisor entry emits one extra event; main unchanged.
        let iters: [[String: Any]] = [
            ["type": "message", "input_tokens": 100, "output_tokens": 50],
            ["type": "advisor_message", "model": "claude-opus-4-8", "input_tokens": 90_000,
             "output_tokens": 1_500, "cache_read_input_tokens": 10, "cache_creation_input_tokens": 20]]
        let it = p.parse(line(id: "m2", ts: t1, block: ["type": "text", "text": "hi"], stop: "end_turn",
                              out: 50, iterations: iters), fileKey: "f", fileSession: "fs", mtime: mt)
        expect(it.count == 2, "one main + one advisor event")
        expect(it[0].event.model == "claude-opus-4-7" && it[0].event.outputTokens == 50
               && it[0].event.inputTokens == 100 && it[0].event.tokenAccuracy == .exact, "main event unchanged")
        let adv = it[1]
        expect(adv.dedupKey == "\(it[0].dedupKey):iter1", "advisor key \(adv.dedupKey)")
        expect(adv.event.model == "claude-opus-4-8" + ClaudeTranscriptParser.advisorModelSuffix
               && adv.event.inputTokens == 90_000 && adv.event.outputTokens == 1_500
               && adv.event.cacheReadTokens == 10 && adv.event.cacheCreationTokens == 20
               && adv.event.provider == .claudeCode && adv.event.sessionId == "s1"
               && adv.event.timestamp == it[0].event.timestamp, "advisor event fields")

        // 4. Missing timestamp: carry forward within the file, mtime if none, never now.
        var q = ClaudeTranscriptParser()
        let first = q.parse(line(id: "m3", ts: nil, block: ["type": "text", "text": "x"], stop: "end_turn"),
                            fileKey: "g", fileSession: "fs", mtime: mt)
        expect(first[0].event.timestamp == Date(timeIntervalSince1970: 1_000), "no prior ts -> mtime")
        let a = q.parse(line(id: "m4", ts: t1, block: ["type": "text", "text": "x"], stop: "end_turn"),
                        fileKey: "g", fileSession: "fs", mtime: mt)
        let b = q.parse(line(id: "m5", ts: nil, block: ["type": "text", "text": "x"], stop: "end_turn"),
                        fileKey: "g", fileSession: "fs", mtime: mt)
        expect(b[0].event.timestamp == a[0].event.timestamp, "missing ts inherits prior line")
        let other = q.parse(line(id: "m6", ts: nil, block: ["type": "text", "text": "x"], stop: "end_turn"),
                            fileKey: "h", fileSession: "fs", mtime: mt)
        expect(other[0].event.timestamp == Date(timeIntervalSince1970: 1_000), "carry-forward is per file")

        // 5. <synthetic> skipped; Ollama-routed model stays exact.
        expect(p.parse(line(id: "m7", ts: t1, block: ["type": "text", "text": "x"], stop: "end_turn",
                            model: "<synthetic>"), fileKey: "f", fileSession: "fs", mtime: mt).isEmpty, "synthetic skipped")
        let oll = p.parse(line(id: "m8", ts: t1, block: ["type": "text", "text": String(repeating: "z", count: 4000)],
                               model: "qwen3:8b"), fileKey: "f", fileSession: "fs", mtime: mt)
        expect(oll[0].event.provider == .ollama && oll[0].event.tokenAccuracy == .exact, "ollama transcript stays exact")

        print("transcript checks passed")
    }

    static func corpus(_ dir: String) {
        let fm = FileManager.default
        // Recursive (all project dirs, subagent files) when CORPUS_RECURSIVE=1.
        let files: [String] = ProcessInfo.processInfo.environment["CORPUS_RECURSIVE"] == "1"
            ? ((fm.enumerator(atPath: dir)?.allObjects as? [String]) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
            : ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
        var p = ClaudeTranscriptParser()
        var best: [String: UsageEvent] = [:]
        var lines = 0
        let marker = Data("\"assistant\"".utf8)
        let t0 = Date()
        for f in files {
            let path = dir + "/" + f
            guard let data = fm.contents(atPath: path) else { continue }
            let mt = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            for raw in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                let d = Data(raw)
                guard d.range(of: marker) != nil else { continue }
                lines += 1
                for o in p.parse(d, fileKey: path, fileSession: f, mtime: { mt }) {
                    best[o.dedupKey] = best[o.dedupKey].map { EventReconciler.preferred($0, o.event) } ?? o.event
                }
            }
        }
        var exactOut = 0, estOut = 0, exactN = 0, estN = 0, advN = 0, advIn = 0, advOut = 0
        for (k, e) in best {
            if k.contains(":iter") { advN += 1; advIn += e.inputTokens; advOut += e.outputTokens; continue }
            if e.tokenAccuracy == .estimated { estOut += e.outputTokens; estN += 1 } else { exactOut += e.outputTokens; exactN += 1 }
        }
        print("files \(files.count) assistant lines \(lines) elapsed \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        print("exact messages \(exactN) output \(exactOut)")
        print("estimated messages \(estN) output \(estOut)")
        print("advisor events \(advN) input \(advIn) output \(advOut)")
    }
}
