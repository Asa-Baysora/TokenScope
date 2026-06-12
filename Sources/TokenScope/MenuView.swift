import SwiftUI
import AppKit

/// Tabbed layout. A custom (snapshot-renderable) tab bar splits the content into
/// Now / Usage / History / Settings; within a tab, each section is collapsible
/// (chevron, persisted) and can be hidden entirely from Settings. The footer
/// (Anthropic service + proxy status) and the menu-bar tint are always present.
///
///   Now      — Limits (nearest rate-limit wall + reset), Live calls, Latest calls
///   Usage    — period-scoped chart, provider/model totals, sessions
///   History  — 6-month activity heatmap
///   Settings — claude.ai cookie, notifications, section visibility
struct MenuView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var limits: LimitsManager
    @ObservedObject var status: StatusManager
    /// Snapshot mode renders the active tab inline: ScrollView is NSScrollView-
    /// backed on macOS and ImageRenderer can't draw it.
    var snapshotInline = false

    @AppStorage("ActiveTab") private var activeTabRaw = Tab.now.rawValue
    @AppStorage("StatsPeriod") private var periodRaw = StatsPeriod.today.rawValue
    @AppStorage("BarChartStyle") private var barStyleRaw = "stacked"
    @AppStorage("HideWeekends") private var hideWeekends = false
    @AppStorage("CollapsedSections") private var collapsedRaw = ""
    @AppStorage("HiddenSections") private var hiddenRaw = ""
    @AppStorage("MenuBarItems") private var menuBarItemsRaw = "tokens"
    @State private var cookieDraft = ""
    @State private var contentHeight: CGFloat = 360

    /// Cap on the scroll viewport; tabs shorter than this shrink to fit (no dead
    /// gap above the footer), taller tabs scroll.
    private static let maxContentHeight: CGFloat = 520

    private struct ContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private var period: StatsPeriod { StatsPeriod(rawValue: periodRaw) ?? .today }
    private var activeTab: Tab { Tab(rawValue: activeTabRaw) ?? .now }

    enum Tab: String, CaseIterable, Identifiable {
        case now, usage, history, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .now: return "Now"
            case .usage: return "Usage"
            case .history: return "History"
            case .settings: return "Settings"
            }
        }
        var icon: String {
            switch self {
            case .now: return "bolt.fill"
            case .usage: return "chart.bar.fill"
            case .history: return "calendar"
            case .settings: return "gearshape.fill"
            }
        }
    }

    enum AppSection: String, CaseIterable, Identifiable {
        case limits, live, latest, chart, providers, sessions, heatmap
        var id: String { rawValue }
        var title: String {
            switch self {
            case .limits: return "Limits"
            case .live: return "Live"
            case .latest: return "Latest calls"
            case .chart: return "Tokens over time"
            case .providers: return "Providers & models"
            case .sessions: return "Sessions"
            case .heatmap: return "Last 6 months"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar.padding(.bottom, 8)
            tabBar.padding(.bottom, 10)
            content
            Divider().padding(.vertical, 8)
            footer
        }
        .padding(12)
        .frame(width: 430)
    }

    @ViewBuilder private var content: some View {
        if snapshotInline {
            tabContent
        } else {
            ScrollView {
                tabContent
                    .padding(.trailing, 2)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    })
            }
            // MenuBarExtra windows size to the view's IDEAL height; a ScrollView's
            // ideal height is ~0, so it MUST get a concrete frame. Measure the
            // content and clamp: short tabs shrink to fit (no dead gap), tall tabs
            // cap and scroll. Never maxHeight-only — that collapses it to zero.
            .frame(height: min(max(contentHeight, 80), Self.maxContentHeight))
            .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch activeTab {
        case .now:      nowTab
        case .usage:    usageTab
        case .history:  historyTab
        case .settings: settingsView
        }
    }

    // MARK: - Title bar & tabs

    private var titleBar: some View {
        let t = store.totals(for: nil, in: .today)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("TokenScope").font(.headline)
            Spacer()
            Text("today  ↑ \(Fmt.compact(t.input))  ↓ \(Fmt.compact(t.output))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases) { tab in
                Button { activeTabRaw = tab.rawValue } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon).font(.system(size: 12))
                        Text(tab.title).font(.system(size: 9.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(activeTab == tab ? Color.accentColor.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(activeTab == tab ? Color.accentColor : .secondary)
            }
        }
    }

    // MARK: - Collapsible / hideable section plumbing

    private func isCollapsed(_ s: AppSection) -> Bool { listContains(collapsedRaw, s.rawValue) }
    private func isHidden(_ s: AppSection) -> Bool { listContains(hiddenRaw, s.rawValue) }
    private func toggleCollapsed(_ s: AppSection) { toggleInList(&collapsedRaw, s.rawValue) }
    private func toggleHidden(_ s: AppSection) { toggleInList(&hiddenRaw, s.rawValue) }

    private func listContains(_ raw: String, _ v: String) -> Bool {
        raw.split(separator: ",").contains(Substring(v))
    }
    private func toggleInList(_ raw: inout String, _ v: String) {
        var set = Set(raw.split(separator: ",").map(String.init))
        if set.contains(v) { set.remove(v) } else { set.insert(v) }
        raw = set.sorted().joined(separator: ",")
    }

    @ViewBuilder
    private func section<Content: View>(_ s: AppSection, @ViewBuilder _ content: () -> Content) -> some View {
        if !isHidden(s) {
            let collapsed = isCollapsed(s)
            VStack(alignment: .leading, spacing: 6) {
                Button { toggleCollapsed(s) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 10)
                        sectionTitle(s.title)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !collapsed { content().padding(.leading, 14) }
            }
        }
    }

    private func tabEmptyNote(_ tab: Tab, sections: [AppSection]) -> some View {
        Group {
            if sections.allSatisfy({ isHidden($0) }) {
                Text("All sections in \(tab.title) are hidden — re-enable them in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Now tab

    private var nowTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            section(.limits) { limitsContent }
            section(.live) { liveContent }
            section(.latest) { callsContent }
            tabEmptyNote(.now, sections: [.limits, .live, .latest])
        }
    }

    @ViewBuilder private var limitsContent: some View {
        if !limits.connected {
            Button { activeTabRaw = Tab.settings.rawValue; cookieDraft = "" } label: {
                HStack(spacing: 6) {
                    Image(systemName: "link").font(.system(size: 10))
                    Text("Connect claude.ai to track session & weekly limits")
                        .font(.system(size: 11.5))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        } else if let err = limits.errorMessage {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                Text(err).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else if limits.windows.isEmpty {
            Text("Loading limits…").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(limits.windows) { w in limitRow(w) }
                if let when = limits.lastUpdated {
                    Text("updated \(Fmt.time.string(from: when))")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func limitRow(_ w: LimitWindow) -> some View {
        let color = LimitsManager.color(forPercent: w.utilization)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(w.label).font(.system(size: 11.5, weight: .medium))
                Spacer()
                if let reset = w.resetsAt {
                    Text("resets \(Self.untilString(reset))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text("\(Int(w.utilization.rounded()))%")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(color)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.18))
                    Capsule().fill(color).frame(width: max(3, geo.size.width * w.fraction))
                }
            }
            .frame(height: 5)
        }
    }

    @ViewBuilder private var liveContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            if store.liveCalls.isEmpty {
                HStack(spacing: 7) {
                    Circle().fill(Color.gray.opacity(0.4)).frame(width: 7, height: 7)
                    Text("Idle — no call in flight")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            ForEach(store.liveCalls) { c in
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 12, height: 12)
                    Text(c.model).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text("↑ \(Fmt.compact(c.inputTokens))   ↓ \(Fmt.compact(c.outputTokens))")
                        .font(.system(size: 12)).monospacedDigit()
                }
            }
            ForEach(store.loadedModels, id: \.name) { m in
                HStack(spacing: 7) {
                    Image(systemName: "memorychip").font(.system(size: 9)).foregroundStyle(.green)
                    Text("\(m.name) in memory\(vram(m))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func vram(_ m: LoadedModel) -> String {
        m.vramBytes > 0 ? String(format: " · %.1f GB", Double(m.vramBytes) / 1_000_000_000) : ""
    }

    @ViewBuilder private var callsContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            let recent = Array(store.events.filter { !$0.shadowed }.suffix(8).reversed())
            if recent.isEmpty { emptyNote("No calls yet") }
            ForEach(recent) { e in
                HStack(spacing: 7) {
                    Text(when(e.timestamp))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                    Circle().fill(color(e.provider)).frame(width: 6, height: 6)
                    Text(e.model).font(.system(size: 11.5)).lineLimit(1)
                    Spacer()
                    Text(callDetail(e)).font(.system(size: 11)).monospacedDigit()
                }
            }
        }
    }

    private func callDetail(_ e: UsageEvent) -> String {
        let cache = e.cacheReadTokens > 0 ? " (+\(Fmt.compact(e.cacheReadTokens)))" : ""
        return "↑ \(Fmt.compact(e.inputTokens))\(cache)  ↓ \(Fmt.compact(e.outputTokens))"
    }

    // MARK: - Usage tab

    private var usageTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("", selection: $periodRaw) {
                    ForEach(StatsPeriod.allCases) { p in Text(p.label).tag(p.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                Spacer()
            }
            section(.chart) { chartBlock }
            section(.providers) {
                VStack(alignment: .leading, spacing: 8) {
                    providerBlock(.claude)
                    providerBlock(.ollama)
                }
            }
            section(.sessions) { sessionsContent }
            tabEmptyNote(.usage, sections: [.chart, .providers, .sessions])
        }
    }

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
                Text(period == .today ? "per hour" : "per day")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if period != .today {
                    Toggle("Hide weekends", isOn: $hideWeekends)
                        .toggleStyle(.checkbox).controlSize(.mini)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Picker("", selection: $barStyleRaw) {
                    Text("Stacked").tag("stacked")
                    Text("Grouped").tag("grouped")
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.mini).fixedSize()
            }
            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(bars) { d in
                        Group {
                            if d.day > now {
                                Color.clear.frame(height: 1.5)
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
                Trendline(totals: pastTotals, slots: bars.count, maxV: maxTotal, spacing: spacing)
                    .frame(height: barHeight)
                    .allowsHitTesting(false)
            }
            HStack {
                Text(leadingEdgeLabel(bars)).font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text(trailingEdgeLabel(bars)).font(.system(size: 9)).foregroundStyle(.secondary)
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
                RoundedRectangle(cornerRadius: 1).fill(Color.blue.opacity(0.85))
                    .frame(height: max(height * CGFloat(d.ollama) / CGFloat(maxV), 1.5))
            }
            if d.claude > 0 {
                RoundedRectangle(cornerRadius: 1).fill(Color.orange.opacity(0.9))
                    .frame(height: max(height * CGFloat(d.claude) / CGFloat(maxV), 1.5))
            }
            if d.total == 0 {
                RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.15)).frame(height: 1.5)
            }
        }
    }

    private func groupedBar(_ d: DayStat, maxV: Int, height: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 1) {
            if d.total == 0 {
                RoundedRectangle(cornerRadius: 1).fill(Color.gray.opacity(0.15)).frame(height: 1.5)
            } else {
                RoundedRectangle(cornerRadius: 1).fill(Color.orange.opacity(0.9))
                    .frame(height: d.claude > 0 ? max(height * CGFloat(d.claude) / CGFloat(maxV), 1.5) : 0)
                RoundedRectangle(cornerRadius: 1).fill(Color.blue.opacity(0.85))
                    .frame(height: d.ollama > 0 ? max(height * CGFloat(d.ollama) / CGFloat(maxV), 1.5) : 0)
            }
        }
    }

    private func providerBlock(_ p: TokenProvider) -> some View {
        let models = store.modelTotals(for: p, in: period)
        let shown = Array(models.prefix(5))
        return VStack(alignment: .leading, spacing: 3) {
            providerRow(p)
            ForEach(shown, id: \.model) { m in
                HStack(spacing: 6) {
                    Text(m.model).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text("↑ \(Fmt.compact(m.totals.input))  ↓ \(Fmt.compact(m.totals.output))  · \(m.totals.calls) calls")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.leading, 17)
            }
            if models.count > shown.count {
                Text("+ \(models.count - shown.count) more models")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.leading, 17)
            }
        }
    }

    private func providerRow(_ p: TokenProvider) -> some View {
        let t = store.totals(for: p, in: period)
        return HStack(spacing: 6) {
            Circle().fill(color(p)).frame(width: 7, height: 7)
            Text(p.displayName).font(.system(size: 12, weight: .medium)).frame(width: 52, alignment: .leading)
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
        .font(.system(size: 12)).monospacedDigit()
    }

    @ViewBuilder private var sessionsContent: some View {
        let all = store.sessions(in: period)
        let sessions = Array(all.prefix(6))
        VStack(alignment: .leading, spacing: 5) {
            if sessions.isEmpty { emptyNote("No sessions in this period") }
            ForEach(sessions) { s in
                HStack(alignment: .top, spacing: 7) {
                    Circle().fill(s.isActive ? Color.green : Color.gray.opacity(0.35))
                        .frame(width: 7, height: 7).padding(.top, 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(s.title).font(.system(size: 12)).lineLimit(1)
                        Text(sessionDetail(s))
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Text(when(s.lastActivity)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            if all.count > sessions.count {
                Text("+ \(all.count - sessions.count) more sessions")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.leading, 14)
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

    // MARK: - History tab

    private static let heatStride: CGFloat = 15   // 13pt cell + 2pt spacing

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            section(.heatmap) { heatmapContent }
            tabEmptyNote(.history, sections: [.heatmap])
        }
    }

    @ViewBuilder private var heatmapContent: some View {
        let weeks = 26
        let cells = store.heatmapDays(weeks: weeks)
        let today = Calendar.current.startOfDay(for: Date())
        let maxV = max(cells.map(\.total).max() ?? 0, 1)
        if cells.count == weeks * 7 {
            VStack(alignment: .leading, spacing: 4) {
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
                    Text("· hue = day's mix · darker = more")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
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
        if labels.count >= 2, labels[0].week == 0, labels[1].week <= 2 {
            labels.removeFirst()
        }
        return ZStack(alignment: .topLeading) {
            ForEach(labels, id: \.week) { l in
                Text(l.text).font(.system(size: 9)).foregroundStyle(.secondary)
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

    // MARK: - Settings tab

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("claude.ai connection")
                Text("Paste your claude.ai Cookie header to track plan limits. At claude.ai/settings/usage: DevTools → Network, refresh, click the \"usage\" request, copy the full Cookie request header.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if limits.connected {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 11))
                        Text("Connected").font(.system(size: 11.5))
                        if let err = limits.errorMessage {
                            Text("· \(err)").font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                        }
                        Spacer()
                        Button("Disconnect") { limits.clearCookie() }.font(.system(size: 11))
                    }
                }
                HStack(spacing: 6) {
                    SecureField("Cookie header value…", text: $cookieDraft)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    Button("Save") { limits.setCookie(cookieDraft); cookieDraft = "" }
                        .font(.system(size: 11))
                        .disabled(cookieDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Stored locally in app preferences, sent only to claude.ai. Unofficial endpoint; may change.")
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle("Menu bar shows")
                Toggle(isOn: menuBarBinding("session")) {
                    Text("Session limit %  ").font(.system(size: 11.5))
                    + Text("(5h, needs claude.ai)").font(.system(size: 9.5)).foregroundColor(.secondary)
                }
                Toggle(isOn: menuBarBinding("weekly")) {
                    Text("Weekly limit %  ").font(.system(size: 11.5))
                    + Text("(7d, needs claude.ai)").font(.system(size: 9.5)).foregroundColor(.secondary)
                }
                Toggle(isOn: menuBarBinding("tokens")) {
                    Text("Daily token count").font(.system(size: 11.5))
                }
                Text("Limit % is colored green / yellow / red by how close it is to the cap.")
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox).controlSize(.small)
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle("Notifications")
                Toggle("Session/weekly limit thresholds (25/50/75/90%)",
                       isOn: Binding(get: { limits.notificationsEnabled }, set: { limits.setNotifications($0) }))
                Toggle("Anthropic service status changes",
                       isOn: Binding(get: { status.notificationsEnabled }, set: { status.setNotifications($0) }))
            }
            .toggleStyle(.checkbox).controlSize(.small).font(.system(size: 11.5))
            VStack(alignment: .leading, spacing: 5) {
                sectionTitle("Show sections")
                ForEach(AppSection.allCases) { s in
                    Toggle(isOn: Binding(get: { !isHidden(s) }, set: { _ in toggleHidden(s) })) {
                        Text("\(s.title)  ").font(.system(size: 11.5))
                        + Text(tabFor(s).title).font(.system(size: 9.5)).foregroundColor(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox).controlSize(.small)
        }
    }

    private func menuBarBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { listContains(menuBarItemsRaw, id) }, set: { _ in toggleInList(&menuBarItemsRaw, id) })
    }

    private func tabFor(_ s: AppSection) -> Tab {
        switch s {
        case .limits, .live, .latest: return .now
        case .chart, .providers, .sessions: return .usage
        case .heatmap: return .history
        }
    }

    // MARK: - Footer (proxy + Anthropic service status)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !status.incidents.isEmpty || !status.degraded.isEmpty {
                ForEach(status.incidents.prefix(2)) { inc in
                    Text("⚠︎ \(inc.name)").font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(1)
                }
                ForEach(status.degraded.prefix(3)) { c in
                    Text("• \(c.name): \(c.status.replacingOccurrences(of: "_", with: " "))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                Circle().fill(status.color).frame(width: 7, height: 7)
                Text(status.allOperational ? "Claude: operational" : status.summary)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Circle().fill(store.proxyHealthy ? Color.green : Color.red).frame(width: 7, height: 7)
                Text(store.proxyHealthy ? "proxy :\(store.proxyPort)" : "proxy down")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                Button("Copy Ollama env") { copyEnv() }
                    .font(.system(size: 11))
                    .help("Copies the env vars that point Claude Code at Ollama through the proxy")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.font(.system(size: 11))
            }
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

    /// "in 2h 14m" / "in 3d 4h" until a reset time.
    static func untilString(_ date: Date) -> String {
        let secs = date.timeIntervalSinceNow
        if secs <= 0 { return "now" }
        let mins = Int(secs / 60)
        if mins < 60 { return "in \(mins)m" }
        let hours = mins / 60
        if hours < 24 { return "in \(hours)h \(mins % 60)m" }
        let days = hours / 24
        return "in \(days)d \(hours % 24)h"
    }

    // MARK: - Shared bits

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE MMM d"; return f
    }()
    private static let shortDayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM"; return f
    }()
    private static let hourFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:00"; return f
    }()

    private func when(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? Fmt.time.string(from: d) : Self.shortDayFmt.string(from: d)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 10, weight: .semibold))
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
