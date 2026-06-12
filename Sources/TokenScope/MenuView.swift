import SwiftUI
import AppKit

/// Layout is four zones, top to bottom by immediacy, each answering one question:
///   Now            — what is happening this second (live calls, model in memory)
///   Usage          — period-scoped stats; the picker lives in THIS zone's header
///   Latest calls   — most recent calls, deliberately not period-scoped
///   Last 6 months  — ambient long-term heatmap, independent of the picker
struct MenuView: View {
    @ObservedObject var store: UsageStore
    /// Snapshot mode renders the scroll content inline: ScrollView is
    /// NSScrollView-backed on macOS and ImageRenderer can't draw it.
    var snapshotInline = false
    @AppStorage("StatsPeriod") private var periodRaw = StatsPeriod.today.rawValue
    @AppStorage("BarChartStyle") private var barStyleRaw = "stacked"
    @AppStorage("HideWeekends") private var hideWeekends = false

    private var period: StatsPeriod { StatsPeriod(rawValue: periodRaw) ?? .today }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
                .padding(.bottom, 10)
            nowZone
            Divider()
                .padding(.vertical, 8)
            if snapshotInline {
                scrollContent
            } else {
                ScrollView {
                    scrollContent
                }
                // Fixed height: MenuBarExtra windows size to the view's ideal height,
                // and a ScrollView's ideal height is ~0 — maxHeight alone collapses it.
                .frame(height: 470)
            }
            Divider()
                .padding(.vertical, 8)
            footer
        }
        .padding(12)
        .frame(width: 430)
    }

    private var scrollContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            usageZone
            Divider().padding(.vertical, 10)
            callsZone
            Divider().padding(.vertical, 10)
            historyZone
        }
    }

    // MARK: - Title bar

    private var titleBar: some View {
        let t = store.totals(for: nil, in: .today)
        return HStack(alignment: .firstTextBaseline) {
            Text("TokenScope").font(.headline)
            Spacer()
            Text("today  ↑ \(Fmt.compact(t.input))  ↓ \(Fmt.compact(t.output))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    // MARK: - Now

    private var nowZone: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Now")
            if store.liveCalls.isEmpty {
                HStack(spacing: 7) {
                    Circle().fill(Color.gray.opacity(0.4)).frame(width: 7, height: 7)
                    Text("Idle — no call in flight")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(store.liveCalls) { c in
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .frame(width: 12, height: 12)
                    Text(c.model)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text("↑ \(Fmt.compact(c.inputTokens))   ↓ \(Fmt.compact(c.outputTokens))")
                        .font(.system(size: 12))
                        .monospacedDigit()
                }
            }
            ForEach(store.loadedModels, id: \.name) { m in
                HStack(spacing: 7) {
                    Image(systemName: "memorychip")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                    Text("\(m.name) in memory\(vram(m))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func vram(_ m: LoadedModel) -> String {
        m.vramBytes > 0 ? String(format: " · %.1f GB", Double(m.vramBytes) / 1_000_000_000) : ""
    }

    // MARK: - Usage (everything in this zone obeys the period picker)

    private var usageZone: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionTitle("Usage")
                Spacer()
                Picker("", selection: $periodRaw) {
                    ForEach(StatsPeriod.allCases) { p in
                        Text(p.label).tag(p.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            chartBlock
            providerBlock(.claude)
            providerBlock(.ollama)
            sessionsBlock
        }
    }

    // MARK: Chart

    private var chartBlock: some View {
        let allBars = period == .today ? store.hourlyTotals() : store.dailyTotals(in: period)
        let bars = (hideWeekends && period != .today)
            ? allBars.filter { !Calendar.current.isDateInWeekend($0.day) }
            : allBars
        let grouped = barStyleRaw == "grouped"
        let maxV = grouped
            ? max(bars.map { max($0.claude, $0.ollama) }.max() ?? 0, 1)
            : max(bars.map(\.total).max() ?? 0, 1)
        let maxTotal = max(bars.map(\.total).max() ?? 0, 1)
        let barHeight: CGFloat = 42
        let spacing: CGFloat = period == .week ? 4 : 2
        let now = Date()
        let pastTotals = bars.filter { $0.day <= now }.map(\.total)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                subLabel(period == .today ? "Tokens per hour" : "Tokens per day")
                Spacer()
                if period != .today {
                    Toggle("Hide weekends", isOn: $hideWeekends)
                        .toggleStyle(.checkbox)
                        .controlSize(.mini)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Picker("", selection: $barStyleRaw) {
                    Text("Stacked").tag("stacked")
                    Text("Grouped").tag("grouped")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
            }
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(bars) { d in
                        Group {
                            if d.day > now {
                                Color.clear.frame(height: 1.5)   // hours/days still to come
                            } else if grouped {
                                groupedBar(d, maxV: maxV, height: barHeight)
                            } else {
                                stackedBar(d, maxV: maxV, height: barHeight)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight, alignment: .bottom)
                        .help(chartHelp(d))
                    }
                }
                // Trend of daily totals; in grouped mode it stays in combined-total
                // scale, so read its shape rather than its height against the bars.
                Trendline(totals: pastTotals, slots: bars.count, maxV: maxTotal, spacing: spacing)
                    .frame(height: barHeight)
                    .allowsHitTesting(false)
            }
            HStack {
                Text(leadingEdgeLabel(bars))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(trailingEdgeLabel(bars))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func trailingEdgeLabel(_ bars: [DayStat]) -> String {
        if period == .today { return "now" }
        guard let last = bars.last else { return "" }
        return Calendar.current.isDateInToday(last.day) ? "today" : Self.shortDayFmt.string(from: last.day)
    }

    private func chartHelp(_ d: DayStat) -> String {
        let label = period == .today ? Self.hourFmt.string(from: d.day) : Self.dayFmt.string(from: d.day)
        return "\(label): Claude \(Fmt.compact(d.claude)) · Ollama \(Fmt.compact(d.ollama))"
    }

    private func leadingEdgeLabel(_ bars: [DayStat]) -> String {
        if period == .today { return "00:00" }
        guard let first = bars.first else { return "" }
        return Self.shortDayFmt.string(from: first.day)
    }

    private func stackedBar(_ d: DayStat, maxV: Int, height: CGFloat) -> some View {
        VStack(spacing: 1) {
            if d.ollama > 0 {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.blue.opacity(0.85))
                    .frame(height: max(height * CGFloat(d.ollama) / CGFloat(maxV), 1.5))
            }
            if d.claude > 0 {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.orange.opacity(0.9))
                    .frame(height: max(height * CGFloat(d.claude) / CGFloat(maxV), 1.5))
            }
            if d.total == 0 {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 1.5)
            }
        }
    }

    private func groupedBar(_ d: DayStat, maxV: Int, height: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 1) {
            if d.total == 0 {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 1.5)
            } else {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.orange.opacity(0.9))
                    .frame(height: d.claude > 0 ? max(height * CGFloat(d.claude) / CGFloat(maxV), 1.5) : 0)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.blue.opacity(0.85))
                    .frame(height: d.ollama > 0 ? max(height * CGFloat(d.ollama) / CGFloat(maxV), 1.5) : 0)
            }
        }
    }

    // MARK: Providers & models

    private func providerBlock(_ p: TokenProvider) -> some View {
        let models = store.modelTotals(for: p, in: period)
        let shown = Array(models.prefix(5))
        return VStack(alignment: .leading, spacing: 3) {
            providerRow(p)
            ForEach(shown, id: \.model) { m in
                HStack(spacing: 6) {
                    Text(m.model)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("↑ \(Fmt.compact(m.totals.input))  ↓ \(Fmt.compact(m.totals.output))  · \(m.totals.calls) calls")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.leading, 17)
            }
            if models.count > shown.count {
                Text("+ \(models.count - shown.count) more models")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 17)
            }
        }
    }

    private func providerRow(_ p: TokenProvider) -> some View {
        let t = store.totals(for: p, in: period)
        return HStack(spacing: 6) {
            Circle().fill(color(p)).frame(width: 7, height: 7)
            Text(p.displayName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 52, alignment: .leading)
            if t.calls == 0 {
                Text("—").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("↑ \(Fmt.compact(t.input))")
                if t.cacheRead > 0 {
                    Text("+\(Fmt.compact(t.cacheRead)) cache")
                        .foregroundStyle(.secondary)
                        .help("Prompt-cache reads: context re-served from cache on each call instead of resent as fresh input. Billed at ~10% of the input rate.")
                }
                Text("↓ \(Fmt.compact(t.output))")
                Spacer()
                Text("\(t.calls) calls").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
    }

    // MARK: Sessions

    private var sessionsBlock: some View {
        VStack(alignment: .leading, spacing: 5) {
            subLabel("Sessions")
            let all = store.sessions(in: period)
            let sessions = Array(all.prefix(6))
            if sessions.isEmpty {
                emptyNote("No sessions in this period")
            }
            ForEach(sessions) { s in
                HStack(alignment: .top, spacing: 7) {
                    Circle()
                        .fill(s.isActive ? Color.green : Color.gray.opacity(0.35))
                        .frame(width: 7, height: 7)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(.system(size: 12)).lineLimit(1)
                        Text(sessionDetail(s))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    Text(when(s.lastActivity))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            if all.count > sessions.count {
                Text("+ \(all.count - sessions.count) more sessions")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 14)
            }
        }
    }

    private func sessionDetail(_ s: SessionAgg) -> String {
        var parts: [String] = []
        if let p = s.project { parts.append(p) }
        if !s.models.isEmpty {
            let models = s.models.sorted()
            parts.append(models.count <= 2 ? models.joined(separator: ", ") : "\(models.count) models")
        }
        parts.append("\(s.totals.calls) calls")
        parts.append("↑ \(Fmt.compact(s.totals.input))")
        if s.totals.cacheRead > 0 { parts.append("+\(Fmt.compact(s.totals.cacheRead)) cache") }
        parts.append("↓ \(Fmt.compact(s.totals.output))")
        return parts.joined(separator: " · ")
    }

    // MARK: - Latest calls (always recent, regardless of period)

    private var callsZone: some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Latest calls")
            let recent = Array(store.events.filter { !$0.shadowed }.suffix(8).reversed())
            if recent.isEmpty {
                emptyNote("No calls yet")
            }
            ForEach(recent) { e in
                HStack(spacing: 7) {
                    Text(when(e.timestamp))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Circle().fill(color(e.provider)).frame(width: 6, height: 6)
                    Text(e.model)
                        .font(.system(size: 11.5))
                        .lineLimit(1)
                    Spacer()
                    Text(callDetail(e))
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
            }
        }
    }

    private func callDetail(_ e: UsageEvent) -> String {
        let cache = e.cacheReadTokens > 0 ? " (+\(Fmt.compact(e.cacheReadTokens)))" : ""
        return "↑ \(Fmt.compact(e.inputTokens))\(cache)  ↓ \(Fmt.compact(e.outputTokens))"
    }

    // MARK: - Last 6 months (independent of the period picker)

    private static let heatStride: CGFloat = 15   // 13pt cell + 2pt spacing

    private var historyZone: some View {
        let weeks = 26
        let cells = store.heatmapDays(weeks: weeks)
        let today = Calendar.current.startOfDay(for: Date())
        let maxV = max(cells.map(\.total).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 4) {
            sectionTitle("Last 6 months")
            if cells.count == weeks * 7 {
                monthLabels(cells: cells, weeks: weeks)
                HStack(spacing: 2) {
                    ForEach(0..<weeks, id: \.self) { w in
                        VStack(spacing: 2) {
                            ForEach(0..<7, id: \.self) { r in
                                heatCell(cells[w * 7 + r], maxV: maxV, today: today)
                            }
                        }
                    }
                }
                HStack(spacing: 5) {
                    Circle().fill(Color(red: 0.96, green: 0.58, blue: 0.20)).frame(width: 6, height: 6)
                    Text("Claude").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    Circle().fill(Color(red: 0.35, green: 0.62, blue: 0.98)).frame(width: 6, height: 6)
                    Text("Ollama").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    Text("· hue = day's mix · darker = more tokens")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
        }
    }

    private func monthLabels(cells: [DayStat], weeks: Int) -> some View {
        let cal = Calendar.current
        var labels: [(week: Int, text: String)] = []
        for w in 0..<weeks {
            let start = cells[w * 7].day
            let month = cal.component(.month, from: start)
            let prev = w > 0 ? cal.component(.month, from: cells[(w - 1) * 7].day) : -1
            if w == 0 || month != prev {
                labels.append((w, Self.monthFmt.string(from: start)))
            }
        }
        // The leading partial month's label collides with the next one if the
        // month boundary falls in the first couple of columns; drop it.
        if labels.count >= 2, labels[0].week == 0, labels[1].week <= 2 {
            labels.removeFirst()
        }
        return ZStack(alignment: .topLeading) {
            ForEach(labels, id: \.week) { l in
                Text(l.text)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .offset(x: CGFloat(l.week) * Self.heatStride)
            }
        }
        .frame(width: CGFloat(weeks) * Self.heatStride - 2, height: 11, alignment: .topLeading)
    }

    private func heatCell(_ d: DayStat, maxV: Int, today: Date) -> some View {
        let future = d.day > today
        return RoundedRectangle(cornerRadius: 3)
            .fill(future ? Color.clear : heatColor(d, maxV))
            .frame(width: 13, height: 13)
            .help(future ? "" : "\(Self.dayFmt.string(from: d.day)): \(Fmt.compact(d.total)) tokens (Claude \(Fmt.compact(d.claude)) · Ollama \(Fmt.compact(d.ollama)))")
    }

    /// Hue mixes the provider colors by that day's share (orange = all Claude,
    /// blue = all Ollama); opacity carries the day's volume vs the period max.
    private func heatColor(_ d: DayStat, _ maxV: Int) -> Color {
        guard d.total > 0 else { return Color.gray.opacity(0.18) }
        let f = Double(d.ollama) / Double(d.total)
        let red = 0.96 + (0.35 - 0.96) * f
        let green = 0.58 + (0.62 - 0.58) * f
        let blue = 0.20 + (0.98 - 0.20) * f
        let t = Double(d.total) / Double(maxV)
        let alpha: Double = t <= 0.25 ? 0.35 : (t <= 0.5 ? 0.55 : (t <= 0.75 ? 0.78 : 1.0))
        return Color(red: red, green: green, blue: blue).opacity(alpha)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.proxyHealthy ? Color.green : Color.red)
                .frame(width: 7, height: 7)
            Text(store.proxyStatus)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Copy Ollama env") { copyEnv() }
                .font(.system(size: 11))
                .help("Copies the env vars that point Claude Code at Ollama through the proxy")
            Button("Quit") { NSApp.terminate(nil) }
                .font(.system(size: 11))
        }
    }

    private func copyEnv() {
        let s = """
        export ANTHROPIC_BASE_URL=http://127.0.0.1:\(store.proxyPort)
        export ANTHROPIC_AUTH_TOKEN=ollama
        """
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    // MARK: - Shared bits

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d"
        return f
    }()

    private static let shortDayFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM"
        return f
    }()

    private static let hourFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:00"
        return f
    }()

    private func when(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? Fmt.time.string(from: d) : Self.shortDayFmt.string(from: d)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func subLabel(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
    }

    private func emptyNote(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(.secondary)
    }

    private func color(_ p: TokenProvider) -> Color {
        switch p {
        case .claude: return .orange
        case .ollama: return .blue
        }
    }
}

/// Dashed trend curve over the chart's daily/hourly totals, fitted with
/// Gaussian kernel regression (Nadaraya–Watson): the curve at x is the average
/// of all observed totals weighted by exp(-((x-xi)/h)²/2). `slots` is the number
/// of displayed bars (including empty future ones) so x-positions line up with
/// bar centers; the fit itself uses only the past bars in `totals`.
private struct Trendline: View {
    let totals: [Int]
    let slots: Int
    let maxV: Int
    let spacing: CGFloat

    var body: some View {
        GeometryReader { geo in
            if totals.count >= 3, slots > 0 {
                let n = totals.count
                let ys = totals.map(Double.init)
                let bandwidth = max(1.25, Double(n) / 6.0)
                let maxV = self.maxV
                let smoothed: (Double) -> Double = { x in
                    var num = 0.0
                    var den = 0.0
                    for i in 0..<n {
                        let u = (x - Double(i)) / bandwidth
                        let w = exp(-0.5 * u * u)
                        num += w * ys[i]
                        den += w
                    }
                    return den > 0 ? num / den : 0
                }
                let slotW = (geo.size.width - spacing * CGFloat(slots - 1)) / CGFloat(slots)
                let point: (Double) -> CGPoint = { x in
                    let px = CGFloat(x) * (slotW + self.spacing) + slotW / 2
                    let v = max(0, min(Double(maxV), smoothed(x)))
                    let py = geo.size.height - CGFloat(v / Double(maxV)) * geo.size.height
                    return CGPoint(x: px, y: py)
                }
                let samples = 64
                Path { p in
                    p.move(to: point(0))
                    for s in 1...samples {
                        p.addLine(to: point(Double(s) / Double(samples) * Double(n - 1)))
                    }
                }
                .stroke(Color.primary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
            }
        }
    }
}
