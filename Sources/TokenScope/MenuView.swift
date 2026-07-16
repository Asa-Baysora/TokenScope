import SwiftUI
import AppKit

/// Tabbed layout. A custom (snapshot-renderable) tab bar splits the content into
/// Now / Usage / History / Settings; within a tab, each section is collapsible
/// (chevron, persisted) and can be hidden entirely from Settings. The footer
/// (Claude + OpenAI service status links) and the menu-bar tint are always
/// present; the proxy health + Ollama env live under Settings.
///
///   Now      — Limits (nearest rate-limit wall + reset), Live calls, Latest calls
///   Usage    — period-scoped chart, source/model totals, sessions
///   History  — 6-month activity heatmap
///   Settings — Sources (per-provider connections) / Display / Notifications
struct MenuView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var limits: LimitsManager
    @ObservedObject var openAILimits: OpenAILimitsManager
    @ObservedObject var chatGPTLimits: ChatGPTLimitsManager
    @ObservedObject var status: StatusManager
    @ObservedObject var openAIStatus: StatusManager
    // Provider accent colors — observed so a Settings color edit re-renders the
    // heatmap, bars, marks, and legend live.
    @ObservedObject private var palette = AppServices.shared.palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    /// Snapshot mode renders the active tab inline: ScrollView is NSScrollView-
    /// backed on macOS and ImageRenderer can't draw it.
    var snapshotInline = false
    /// Deterministic visual-test fixture. Production callers leave this nil and
    /// the rail is built exclusively from the live managers.
    var snapshotLimitReadings: [LimitRailReading]?

    @AppStorage("ActiveTab") private var activeTabRaw = Tab.usage.rawValue
    @AppStorage("StatsPeriod") private var periodRaw = StatsPeriod.today.rawValue
    @AppStorage("BarChartStyle") private var barStyleRaw = "stacked"
    @AppStorage("HideWeekends") private var hideWeekends = false
    // Cache reads/writes are most of the real context volume, so the chart
    // counts them by default; Settings can drop them for an in/out-only view.
    @AppStorage("ChartIncludeCache") private var chartIncludeCache = true
    @AppStorage("CollapsedSections") private var collapsedRaw = ""
    @AppStorage("HiddenSections") private var hiddenRaw = ""
    @AppStorage("MenuBarItems") private var menuBarItemsRaw = "tokens"
    // How Codex usage is tracked: "local" (this Mac's ~/.codex sessions) or
    // "cookie" (the ChatGPT web endpoint — comprehensive & always current). Empty
    // = auto: prefer the cookie when one is connected, else local.
    @AppStorage("CodexSource") private var codexSourceRaw = ""
    @AppStorage("SessionOriginFilter") private var sessionOriginFilterRaw = SessionOriginFilter.all.rawValue
    @State private var cookieDraft = ""
    @State private var chatGPTCookieDraft = ""
    @State private var hexDraft: [String: String] = [:]   // per-provider hex field text
    @State private var contentHeight: CGFloat = 360
    @State private var usageDetail: UsageDetail?
    @State private var settingsPanel: SettingsPanel?

    /// Cap on the scroll viewport; tabs shorter than this shrink to fit (no dead
    /// gap above the footer), taller tabs scroll.
    private static let maxContentHeight: CGFloat = 520

    private struct ContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private var period: StatsPeriod { StatsPeriod(rawValue: periodRaw) ?? .today }
    private var activeTab: Tab { Tab(rawValue: activeTabRaw) ?? .usage }
    private var sessionOriginFilter: SessionOriginFilter {
        SessionOriginFilter(rawValue: sessionOriginFilterRaw) ?? .all
    }

    // Codex has two interchangeable sources; the header + menu bar read whichever
    // one is active. With no explicit choice, auto-prefer the cookie when connected.
    private var codexUsesCookie: Bool {
        switch codexSourceRaw {
        case "cookie": return true
        case "local":  return false
        default:       return chatGPTLimits.connected
        }
    }
    private var codexConfigured: Bool { codexUsesCookie ? chatGPTLimits.connected : openAILimits.monitoringEnabled }
    private var codexWindows: [LimitWindow] { codexUsesCookie ? chatGPTLimits.windows : openAILimits.windows }

    // Raw value stays "now" (persisted in AppStorage) though it's titled "Activity".
    enum Tab: String, CaseIterable, Identifiable {
        case usage, now, history, settings
        var id: String { rawValue }
        var title: String {
            switch self {
            case .now: return "Activity"
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

    enum UsageDetail: String {
        case providers
        case sessions
    }

    enum SettingsPanel: String {
        case connections
        case menuBar
        case colors
        case chart
        case notifications
    }

    // Limits is NOT here — it's an always-visible header (different scope/unit:
    // account-wide %, not local token counts). These are the local-token sections.
    enum AppSection: String, CaseIterable, Identifiable {
        case live, latest, chart, providers, performance, sessions, heatmap
        var id: String { rawValue }
        var title: String {
            switch self {
            case .live: return "Live"
            case .latest: return "Latest calls"
            case .chart: return "Tokens over time"
            case .providers: return "Providers & models"
            case .performance: return "Performance & reliability"
            case .sessions: return "Sessions & activity"
            case .heatmap: return "Last 6 months"
            }
        }
    }

    enum SessionOriginFilter: String, CaseIterable, Identifiable {
        case all, claudeCode, codex, ollama, lmStudio

        var id: String { rawValue }
        var origin: UsageOrigin? { UsageOrigin(rawValue: rawValue) }
        var label: String {
            switch self {
            case .all: return "All"
            case .claudeCode: return "Claude"
            case .codex: return "Codex"
            case .ollama: return "Ollama"
            case .lmStudio: return "LM Studio"
            }
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            redesignedHeader.padding(.bottom, 13)
            redesignedLimitsRail.padding(.bottom, 15)
            redesignedFacetBody
            tabBar.padding(.top, 14)
        }
        .padding(.horizontal, 17)
        .padding(.top, 15)
        .padding(.bottom, 14)
        .frame(width: 430)
        .background {
            if snapshotInline {
                colorScheme == .dark ? Color.black : Color.white
            }
        }
    }

    private static let facetHeight: CGFloat = 304

    @ViewBuilder private var redesignedFacetBody: some View {
        if snapshotInline {
            redesignedTabContent
                .frame(maxWidth: .infinity, minHeight: Self.facetHeight,
                       maxHeight: Self.facetHeight, alignment: .top)
                .clipped()
        } else {
            ScrollView {
                redesignedTabContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.trailing, 2)
            }
            .frame(height: Self.facetHeight)
        }
    }

    @ViewBuilder private var redesignedTabContent: some View {
        switch activeTab {
        case .usage: usageFacet
        case .now: activityFacet
        case .history: historyFacet
        case .settings: settingsFacet
        }
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
        let totals = UsageOrigin.allCases.map { ($0, store.totals(for: $0, in: .today)) }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("TokenScope").font(.headline)
            Spacer()
            // Today's tokens split by provider — a single merged number is
            // misleading (often dominated by free local Ollama traffic).
            HStack(spacing: 7) {
                Text("today").font(.system(size: 10)).foregroundStyle(.secondary)
                ForEach(totals.filter { $0.1.calls > 0 }, id: \.0.rawValue) { origin, total in
                    providerTotalChip(origin, total.input + total.output)
                }
                if totals.allSatisfy({ $0.1.calls == 0 }) {
                    Text("—").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
        }
    }

    private func providerTotalChip(_ p: UsageOrigin, _ total: Int) -> some View {
        HStack(spacing: 3.5) {
            BrandMarkView(origin: p, size: 11)
            Text(Fmt.compact(total)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .help("\(p.displayName) tokens today (input + output)")
    }

    // Flat segmented control on top of the system glass popup: one subtle
    // container, a single solid accent selection capsule, consistent radii.
    // No nested glass (that was the "mess of radius and glass").
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { tab in
                let selected = activeTab == tab
                Button {
                    animateFacetChange {
                        activeTabRaw = tab.rawValue
                        if tab != .usage { usageDetail = nil }
                        if tab != .settings { settingsPanel = nil }
                    }
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: tab.icon).font(.system(size: 12))
                        Text(tab.title).font(.system(size: 9.5, weight: selected ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selectionSurface)
                                .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func animateFacetChange(_ change: @escaping () -> Void) {
        if reduceMotion { change() }
        else { withAnimation(.easeInOut(duration: 0.15), change) }
    }

    private var selectionSurface: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.82)
    }

    // MARK: - Redesigned persistent chrome

    private var redesignedHeader: some View {
        let aggregate = aggregateServiceStatus
        return HStack(spacing: 8) {
            Circle()
                .stroke(Color.primary, lineWidth: 2)
                .frame(width: 9, height: 9)
            Text("TokenScope")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button {
                NSWorkspace.shared.open(aggregate.url)
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(aggregate.color).frame(width: 6, height: 6)
                    Text(aggregate.text)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open \(aggregate.url.host ?? "service status")")
        }
    }

    private var aggregateServiceStatus: (text: String, color: Color, url: URL) {
        let services = [status, openAIStatus]
        let affected = services.filter { !$0.allOperational }
        guard !affected.isEmpty else {
            return ("operational", Self.statusGreen, status.service.statusURL)
        }
        let worst = affected.max { serviceRank($0.indicator) < serviceRank($1.indicator) } ?? affected[0]
        let names = affected.map { $0.service.displayName }.joined(separator: " + ")
        return ("\(names): \(worst.summary)", worst.color, worst.service.statusURL)
    }

    private func serviceRank(_ indicator: String) -> Int {
        switch indicator {
        case "critical": return 3
        case "major": return 2
        case "minor": return 1
        default: return 0
        }
    }

    private static let statusGreen = Color(red: 48 / 255, green: 184 / 255, blue: 92 / 255)
    private static let warningAmber = Color(red: 232 / 255, green: 152 / 255, blue: 27 / 255)
    private static let dangerRed = Color(red: 229 / 255, green: 72 / 255, blue: 77 / 255)

    private var limitRailReadings: [LimitRailReading] {
        if let snapshotLimitReadings {
            return LimitRailPresentation.ordered(snapshotLimitReadings)
        }
        var readings: [LimitRailReading] = []
        func add(_ window: LimitWindow?, provider: LimitRailProvider,
                 period: LimitRailPeriod, fallback: String) {
            guard let window else { return }
            let owner = provider == .codex ? "Codex" : "Claude"
            let duration = window.period?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayDuration = (duration?.isEmpty == false ? duration : nil) ?? fallback
            readings.append(LimitRailReading(
                id: "\(provider.rawValue):\(window.id)", provider: provider, period: period,
                label: "\(owner) \(displayDuration)",
                utilization: window.utilization, resetsAt: window.resetsAt))
        }

        add(codexWindows.first { $0.id == "codex-primary" }, provider: .codex,
            period: .primary, fallback: "5h")
        add(codexWindows.first { $0.id == "codex-secondary" }, provider: .codex,
            period: .secondary, fallback: "7d")
        add(limits.windows.first { $0.id == "five_hour" }, provider: .claude,
            period: .primary, fallback: "5h")
        add(limits.windows.first { $0.id == "seven_day" }, provider: .claude,
            period: .secondary, fallback: "7d")
        return LimitRailPresentation.ordered(readings)
    }

    @ViewBuilder private var redesignedLimitsRail: some View {
        let readings = limitRailReadings
        if readings.isEmpty {
            Button {
                settingsPanel = .connections
                activeTabRaw = Tab.settings.rawValue
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                    Text(codexConfigured || limits.connected
                         ? "Awaiting quota data" : "Connect limits to show the nearest cap")
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 11).padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.035)))
            }
            .buttonStyle(.plain)
            .frame(height: 81)
        } else {
            let nearest = LimitRailPresentation.nearestID(in: readings)
            HStack(alignment: .top, spacing: 6) {
                ForEach(readings) { reading in
                    limitRailCell(reading, nearest: reading.id == nearest)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 81)
        }
    }

    private func limitRailCell(_ reading: LimitRailReading, nearest: Bool) -> some View {
        let color = limitColor(reading.severity)
        return VStack(alignment: .leading, spacing: 0) {
            Text(nearest ? "◆ NEAREST" : " ")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(nearest ? color : Color.clear)
                .lineLimit(1)
                .frame(height: 11)
            Text(reading.label)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 2)
            Text("\(Int(reading.utilization.rounded()))%")
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .padding(.vertical, 2)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.09))
                    Capsule().fill(color)
                        .frame(width: geo.size.width * reading.fraction)
                }
            }
            .frame(height: 3)
            Text(reading.resetsAt.map { Self.untilString($0).replacingOccurrences(of: "in ", with: "") } ?? "reset —")
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.top, 5)
                .lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.top, 8).padding(.bottom, 9)
        .frame(minHeight: 81, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(nearest ? color.opacity(0.10) : Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .stroke(nearest ? color.opacity(0.35) : Color.primary.opacity(0.06), lineWidth: 1))
        .help("\(reading.label): \(Int(reading.utilization.rounded()))% used\(nearest ? ", nearest limit" : "")")
    }

    private func limitColor(_ severity: LimitSeverity) -> Color {
        switch severity {
        case .healthy: return Self.statusGreen
        case .warning: return Self.warningAmber
        case .danger: return Self.dangerRed
        }
    }

    // MARK: - Redesigned facets

    @ViewBuilder private var usageFacet: some View {
        if let detail = usageDetail { usageDetailFacet(detail) }
        else { usageSummaryFacet }
    }

    private var usageSummaryFacet: some View {
        let totals = store.totals(for: nil, in: period)
        let fresh = totals.input + totals.output
        let cached = totals.cacheRead + totals.cacheCreate
        let headline = fresh + (chartIncludeCache ? cached : 0)
        let claude = usageTokens(for: .claudeCode)
        let codex = usageTokens(for: .codex)
        let splitMax = max(max(claude, codex), 1)
        let spark = usageSparkValues
        let peak = spark.enumerated().max { $0.element < $1.element }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                periodSelector
                Spacer()
                Text(period == .today ? "per hour\(chartIncludeCache ? " · incl. cache" : "")"
                                      : "per day\(chartIncludeCache ? " · incl. cache" : "")")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 12)

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(Fmt.compact(headline))
                    .font(.system(size: 38, weight: .semibold, design: .monospaced))
                    .tracking(-1.1)
                Text("tokens")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.bottom, 11)

            if !isHidden(.providers) {
                VStack(spacing: 9) {
                    providerUsageBar(.claudeCode, value: claude, maxValue: splitMax)
                    providerUsageBar(.codex, value: codex, maxValue: splitMax)
                }
                .padding(.bottom, 9)
            }

            if !isHidden(.chart) {
                usageSparkline(spark)
                    .frame(height: 49)
                HStack {
                    Text(period == .today ? "00:00" : period.label)
                    Spacer()
                    if let peak {
                        Text("peak \(sparkPeakLabel(peak.offset)) · \(Fmt.compact(peak.element))")
                    }
                    Spacer()
                    Text(period == .today ? "now" : "today")
                }
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 9)
            }

            HStack(spacing: 7) {
                usageChip(title: "fresh in/out", value: Fmt.compact(fresh))
                usageChip(title: "cache", value: Fmt.compact(cached))
                if !isHidden(.sessions) {
                    Button { animateFacetChange { usageDetail = .sessions } } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("top project").font(.system(size: 9)).foregroundStyle(.secondary)
                            Text(topProjectName ?? "No project yet")
                                .font(.system(size: 11.5, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.035)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var periodSelector: some View {
        HStack(spacing: 2) {
            ForEach(StatsPeriod.allCases) { option in
                let selected = period == option
                Button { animateFacetChange { periodRaw = option.rawValue } } label: {
                    Text(option.label)
                        .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 6).fill(selectionSurface)
                                    .shadow(color: .black.opacity(0.10), radius: 1, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func providerUsageBar(_ provider: UsageOrigin, value: Int, maxValue: Int) -> some View {
        Button { animateFacetChange { usageDetail = .providers } } label: {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    BrandMarkView(origin: provider, size: 10)
                    Text(provider == .claudeCode ? "Claude Code" : provider.displayName)
                        .font(.system(size: 11.5))
                    Spacer()
                    Text(Fmt.compact(value)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule().fill(palette.color(provider))
                            .frame(width: geo.size.width * CGFloat(value) / CGFloat(maxValue))
                    }
                }
                .frame(height: 7)
            }
        }
        .buttonStyle(.plain)
    }

    private func usageTokens(for provider: UsageOrigin) -> Int {
        let totals = store.totals(for: provider, in: period)
        return totals.input + totals.output
            + (chartIncludeCache ? totals.cacheRead + totals.cacheCreate : 0)
    }

    private var usageSparkValues: [Int] {
        let stats = period == .today
            ? store.hourlyTotals(includeCache: chartIncludeCache)
            : store.dailyTotals(in: period, includeCache: chartIncludeCache)
        return stats.map(\.total)
    }

    private func usageSparkline(_ values: [Int]) -> some View {
        GeometryReader { geo in
            let line = sparklinePath(values, size: geo.size, closed: false)
            let fill = sparklinePath(values, size: geo.size, closed: true)
            ZStack {
                fill.fill(LinearGradient(colors: [Color.accentColor.opacity(0.22), .clear],
                                         startPoint: .top, endPoint: .bottom))
                line.stroke(Color.accentColor.opacity(0.72),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }

    private func sparklinePath(_ values: [Int], size: CGSize, closed: Bool) -> Path {
        var path = Path()
        guard !values.isEmpty else { return path }
        let maxValue = max(values.max() ?? 0, 1)
        let denominator = max(values.count - 1, 1)
        let points = values.enumerated().map { index, value in
            CGPoint(x: size.width * CGFloat(index) / CGFloat(denominator),
                    y: size.height - size.height * CGFloat(value) / CGFloat(maxValue))
        }
        path.move(to: points[0])
        points.dropFirst().forEach { path.addLine(to: $0) }
        if closed {
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
        return path
    }

    private func sparkPeakLabel(_ index: Int) -> String {
        if period == .today { return String(format: "%02d:00", index) }
        let days = period == .week ? 7 : 30
        let offset = index - (days - 1)
        guard let date = Calendar.current.date(byAdding: .day, value: offset, to: Date()) else { return "" }
        return Self.shortDayFmt.string(from: date)
    }

    private func usageChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.035)))
    }

    private var topProjectName: String? {
        var totals: [String: Int] = [:]
        for event in store.events(in: period) {
            guard let project = event.projectName, !project.isEmpty else { continue }
            totals[project, default: 0] += event.inputTokens + event.outputTokens
                + (chartIncludeCache ? event.cacheReadTokens + event.cacheCreationTokens : 0)
        }
        return totals.max { $0.value < $1.value }?.key
    }

    private func usageDetailFacet(_ detail: UsageDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            facetBackButton(title: detail == .providers ? "Providers & models" : "Sessions & activity") {
                animateFacetChange { usageDetail = nil }
            }
            periodSelector
            if detail == .providers {
                VStack(alignment: .leading, spacing: 10) {
                    providerBlock(.claudeCode)
                    providerBlock(.codex)
                    providerBlock(.ollama)
                    providerBlock(.lmStudio)
                }
            } else {
                sessionsContent
            }
        }
    }

    private var activityFacet: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isHidden(.live) {
                facetLabel("Now").padding(.bottom, 8)
                liveContent
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Color.primary.opacity(0.035)))
                    .padding(.bottom, 14)
            }
            if !isHidden(.latest) {
                facetLabel("Latest calls").padding(.bottom, 7)
                callsContent
            }
            if isHidden(.live) && isHidden(.latest) {
                emptyNote("Activity details are hidden — re-enable them in Settings")
            }
        }
    }

    private var historyFacet: some View {
        let models = Array(PerformanceAggregator.summarizeByModel(store.events(in: .month)).prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            if !isHidden(.heatmap) {
                facetLabel("Last 6 months").padding(.bottom, 8)
                heatmapContent.padding(.bottom, 14)
            }
            if !isHidden(.performance) {
                facetLabel("Model performance · medians").padding(.bottom, 7)
                if models.isEmpty {
                    emptyNote("No model performance data yet")
                } else {
                    VStack(spacing: 7) {
                        ForEach(models) { summary in
                            HStack(spacing: 8) {
                                BrandMarkView(origin: summary.provider, size: 10)
                                Text(summary.model).font(.system(size: 11.5)).lineLimit(1)
                                Spacer()
                                Text(modelPerformanceDetail(summary))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            if isHidden(.heatmap) && isHidden(.performance) {
                emptyNote("History details are hidden — re-enable them in Settings")
            }
        }
    }

    private func modelPerformanceDetail(_ summary: ModelPerformanceSummary) -> String {
        var parts: [String] = []
        if let tps = summary.medianTokensPerSecond { parts.append(String(format: "%.1f tok/s", tps)) }
        if let ttft = summary.medianTimeToFirstTokenSeconds { parts.append(String(format: "%.2fs TTFT", ttft)) }
        if summary.failed > 0 { parts.append("\(summary.failed) failed") }
        if parts.isEmpty { parts.append("\(summary.calls) calls") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var settingsFacet: some View {
        if let panel = settingsPanel { settingsDetailFacet(panel) }
        else {
            VStack(spacing: 0) {
                settingsRow(icon: "link", title: "Connections",
                            subtitle: "Claude · Codex · Ollama · LM Studio", panel: .connections)
                settingsRow(icon: "menubar.rectangle", title: "Menu bar shows",
                            subtitle: "Daily tokens · nearest limit %", panel: .menuBar)
                settingsRow(icon: "circle.lefthalf.filled", title: "Provider colors",
                            subtitle: "Claude · Codex · Ollama · LM Studio", panel: .colors)
                settingsRow(icon: "chart.line.uptrend.xyaxis", title: "Usage chart",
                            subtitle: chartIncludeCache ? "Includes cached tokens" : "Fresh tokens only", panel: .chart)
                settingsRow(icon: "bell", title: "Notifications",
                            subtitle: "Limit thresholds · service status", panel: .notifications)
            }
        }
    }

    private func settingsRow(icon: String, title: String, subtitle: String,
                             panel: SettingsPanel) -> some View {
        Button { animateFacetChange { settingsPanel = panel } } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 9).padding(.horizontal, 2)
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func settingsDetailFacet(_ panel: SettingsPanel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            facetBackButton(title: settingsTitle(panel)) {
                animateFacetChange { settingsPanel = nil }
            }
            switch panel {
            case .connections:
                claudeSourceGroup
                codexSourceGroup
                ollamaSourceGroup
                lmStudioSourceGroup
            case .menuBar:
                menuBarGroup
                Button("Quit TokenScope") { NSApplication.shared.terminate(nil) }
                    .font(.system(size: 11.5)).foregroundStyle(.red)
            case .colors:
                providerColorsGroup
            case .chart:
                usageChartGroup
                showSectionsGroup
            case .notifications:
                notificationsGroup
            }
        }
    }

    private func settingsTitle(_ panel: SettingsPanel) -> String {
        switch panel {
        case .connections: return "Connections"
        case .menuBar: return "Menu bar shows"
        case .colors: return "Provider colors"
        case .chart: return "Usage chart"
        case .notifications: return "Notifications"
        }
    }

    private func facetBackButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 12.5, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
    }

    private func facetLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(.tertiary)
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
            VStack(alignment: .leading, spacing: collapsed ? 0 : 8) {
                Button { withAnimation(.easeInOut(duration: 0.18)) { toggleCollapsed(s) } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                            .frame(width: 10)
                        sectionTitle(s.title)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if !collapsed { content() }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sectionCard(cornerRadius: 13)
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
            section(.live) { liveContent }
            section(.latest) { callsContent }
            tabEmptyNote(.now, sections: [.live, .latest])
        }
    }

    // MARK: - Account-limit headers (always visible above the tabs)

    private var accountLimitsHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cookie-backed Claude card stays hidden until configured; Settings is
            // the explicit connection point.
            if limits.connected { limitsHeader }
            // One Codex card, fed by the selected source (local or cookie).
            codexLimitsHeader
        }
    }

    /// claude.ai plan limits. Pulled out of the tabs because it's a different
    /// scope and unit from everything else: account-wide utilization % (covers
    /// claude.ai web + desktop + Claude Code), not local token counts. Always
    /// on-screen since "how close to the wall" is the most actionable glance.
    @ViewBuilder private var limitsHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("CLAUDE LIMITS")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if limits.connected, !limits.windows.isEmpty { refreshButton }
            }
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
            } else if let err = limits.errorMessage, limits.windows.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                    Text(err).font(.system(size: 11)).foregroundStyle(.secondary)
                    refreshButton
                }
            } else if limits.windows.isEmpty {
                HStack(spacing: 6) {
                    Text("Loading limits…").font(.system(size: 11)).foregroundStyle(.secondary)
                    refreshButton
                }
            } else {
                ForEach(limits.windows) { w in limitRow(w) }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionCard(cornerRadius: 13)
    }

    @ViewBuilder private var codexLimitsHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("CODEX LIMITS")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { codexUsesCookie ? chatGPTLimits.refresh() : openAILimits.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!codexConfigured)
                .help(codexUsesCookie ? "Refresh Codex limits from ChatGPT" : "Refresh limits from local Codex sessions")
            }
            if !codexConfigured {
                Button { activeTabRaw = Tab.settings.rawValue } label: {
                    HStack(spacing: 6) {
                        Image(systemName: codexUsesCookie ? "link" : "gearshape").font(.system(size: 10))
                        Text(codexUsesCookie ? "Connect ChatGPT to track Codex limits"
                                             : "Enable Codex tracking in Settings").font(.system(size: 11.5))
                    }
                }
                .buttonStyle(.plain).foregroundStyle(.blue)
            } else if codexWindows.isEmpty {
                HStack(spacing: 6) {
                    Text(codexUsesCookie
                         ? (chatGPTLimits.errorMessage ?? "Loading Codex limits…")
                         : "Awaiting a local Codex turn to report quota status.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if codexUsesCookie { chatGPTRefreshButton }
                }
            } else {
                ForEach(codexWindows) { limitRow($0) }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sectionCard(cornerRadius: 13)
    }


    private var refreshButton: some View {
        Button { limits.refresh() } label: {
            Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Refresh limit usage now")
    }

    private var chatGPTRefreshButton: some View {
        Button { chatGPTLimits.refresh() } label: {
            Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Refresh ChatGPT web limits now")
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
                    BrandMarkView(origin: c.provider, size: 12)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.model).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if c.operation != .unknown {
                            Text(operationLabel(c.operation)).font(.system(size: 9.5)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("↑ \(Fmt.compact(c.inputTokens))   ↓ \(accuracyPrefix(c.outputAccuracy))\(Fmt.compact(c.outputTokens))")
                        .font(.system(size: 12)).monospacedDigit()
                }
            }
            ForEach(store.loadedModels) { m in
                HStack(spacing: 7) {
                    BrandMarkView(origin: m.provider, size: 11)
                    Image(systemName: "memorychip").font(.system(size: 9)).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(m.name).font(.system(size: 11)).lineLimit(1)
                        Text(loadedModelDetail(m))
                            .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }

    private func loadedModelDetail(_ m: LoadedModel) -> String {
        var parts = [m.provider.displayName]
        if m.isGenerating == true { parts.append("generating") }
        if let queued = m.queuedRequests, queued > 0 { parts.append("\(queued) queued") }
        if m.vramBytes > 0 {
            parts.append(String(format: "%.1f GB VRAM", Double(m.vramBytes) / 1_000_000_000))
        } else if m.sizeBytes > 0 {
            parts.append(String(format: "%.1f GB", Double(m.sizeBytes) / 1_000_000_000))
        }
        if let context = m.contextLength, context > 0 { parts.append("\(Fmt.compact(context)) ctx") }
        if let parallel = m.parallelCapacity, parallel > 1 { parts.append("\(parallel) parallel") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var callsContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            let recent = Array(store.events.filter { !$0.shadowed }.suffix(8).reversed())
            if recent.isEmpty { emptyNote("No calls yet") }
            ForEach(recent) { e in
                HStack(spacing: 7) {
                    Text(when(e.timestamp))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                    BrandMarkView(origin: e.provider, size: 12)
                    if e.status == .failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9)).foregroundStyle(.orange)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(e.model).font(.system(size: 11.5)).lineLimit(1)
                        if e.operation != .unknown {
                            Text(operationLabel(e.operation)).font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(callDetail(e)).font(.system(size: 10.5)).monospacedDigit()
                }
                .help(callHelp(e))
            }
        }
    }

    private func callDetail(_ e: UsageEvent) -> String {
        if e.status == .failed {
            return e.httpStatus.map { "failed · \($0)" } ?? "failed"
        }
        let cache = e.cacheReadTokens > 0 ? " +\(Fmt.compact(e.cacheReadTokens)) cache" : ""
        let performance = e.tokensPerSecond.map { String(format: " · %.1f t/s", $0) }
            ?? e.durationSeconds.map { String(format: " · %.1fs", $0) }
            ?? ""
        if e.tokenAccuracy == .unknown && e.inputTokens == 0 && e.outputTokens == 0 {
            return "tokens unavailable\(performance)"
        }
        return "↑ \(Fmt.compact(e.inputTokens))\(cache)  ↓ \(accuracyPrefix(e.tokenAccuracy))\(Fmt.compact(e.outputTokens))\(performance)"
    }

    private func callHelp(_ e: UsageEvent) -> String {
        var parts = [e.provider.displayName, operationLabel(e.operation), e.status.rawValue]
        if e.tokenAccuracy == .unknown {
            parts.append(e.inputTokens == 0 && e.outputTokens == 0
                         ? "token counts unavailable" : "token accuracy unknown")
        } else {
            parts.append(e.tokenAccuracy == .estimated ? "estimated tokens" : "\(e.tokenAccuracy.rawValue) tokens")
        }
        if let duration = e.durationSeconds { parts.append(String(format: "%.2fs duration", duration)) }
        if let ttft = e.timeToFirstTokenSeconds { parts.append(String(format: "%.2fs TTFT", ttft)) }
        if let tps = e.tokensPerSecond { parts.append(String(format: "%.1f tokens/s", tps)) }
        if let category = e.errorCategory { parts.append(category) }
        return parts.joined(separator: " · ")
    }

    private func accuracyPrefix(_ accuracy: MetricAccuracy) -> String {
        accuracy == .estimated ? "~" : ""
    }

    private func operationLabel(_ operation: InferenceOperation) -> String {
        switch operation {
        case .chat: return "chat"
        case .generate: return "generate"
        case .completion: return "completion"
        case .responses: return "responses"
        case .embedding: return "embedding"
        case .image: return "image"
        case .unknown: return "inference"
        }
    }

    // MARK: - Usage tab

    private var usageTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $periodRaw) {
                    ForEach(StatsPeriod.allCases) { p in Text(p.label).tag(p.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                Spacer()
            }
            Text("Local tokens observed on this Mac: Claude, Codex, Ollama, and LM Studio (excludes web/desktop ChatGPT and claude.ai).")
                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            section(.chart) { chartBlock }
            section(.providers) {
                VStack(alignment: .leading, spacing: 8) {
                    providerBlock(.claudeCode)
                    providerBlock(.codex)
                    providerBlock(.ollama)
                    providerBlock(.lmStudio)
                }
            }
            section(.performance) { performanceContent }
            section(.sessions) { sessionsContent }
            tabEmptyNote(.usage, sections: [.chart, .providers, .performance, .sessions])
        }
    }

    @ViewBuilder private var performanceContent: some View {
        let summaries = PerformanceAggregator.summarize(store.events(in: period))
        if summaries.isEmpty {
            emptyNote("No local-runtime performance data in this period")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summaries) { summary in performanceRow(summary) }
                Text("Medians use only calls where the runtime reported that metric. ~ means a streamed count was estimated before final usage arrived.")
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func performanceRow(_ summary: ProviderPerformanceSummary) -> some View {
        HStack(alignment: .top, spacing: 7) {
            BrandMarkView(origin: summary.provider, size: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(summary.provider.displayName).font(.system(size: 12, weight: .medium))
                    Text("\(summary.calls) calls").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    // fixedSize per metric: without it a tight row wraps
                    // mid-unit ("tok/ s median") instead of overflowing cleanly.
                    if let tps = summary.medianTokensPerSecond {
                        Text(String(format: "%.1f tok/s median", tps)).fixedSize()
                    }
                    if let ttft = summary.medianTimeToFirstTokenSeconds {
                        Text(String(format: "%.2fs TTFT", ttft)).fixedSize()
                    }
                    if let duration = summary.medianDurationSeconds {
                        Text(String(format: "%.1fs duration", duration)).fixedSize()
                    }
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if summary.failed > 0 {
                    Text("\(summary.failed) failed").foregroundStyle(.orange)
                } else {
                    Text("\(summary.succeeded) completed").foregroundStyle(.secondary)
                }
                if summary.cancelled > 0 { Text("\(summary.cancelled) cancelled").foregroundStyle(.secondary) }
                if summary.estimated > 0 { Text("\(summary.estimated) estimated").foregroundStyle(.secondary) }
                if summary.unknownTokens > 0 { Text("\(summary.unknownTokens) tokens unavailable").foregroundStyle(.secondary) }
            }
            .font(.system(size: 10)).monospacedDigit()
        }
    }

    /// Compact toggle/choice pill for the chart header — mirrors the session
    /// filter's styling so the Usage tab reads as one system.
    private func chartPill(_ label: String, selected: Bool, help: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 10, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : .secondary)
        .fixedSize()
        .help(help)
    }

    private var chartBlock: some View {
        let allBars = period == .today
            ? store.hourlyTotals(includeCache: chartIncludeCache)
            : store.dailyTotals(in: period, includeCache: chartIncludeCache)
        let bars = (hideWeekends && period != .today)
            ? allBars.filter { !Calendar.current.isDateInWeekend($0.day) }
            : allBars
        let grouped = barStyleRaw == "grouped"
        let maxV = grouped
            ? max(bars.map { max(max($0.claude, $0.codex), max($0.ollama, $0.lmStudio)) }.max() ?? 0, 1)
            : max(bars.map(\.total).max() ?? 0, 1)
        let maxTotal = max(bars.map(\.total).max() ?? 0, 1)
        let barHeight: CGFloat = 42
        let spacing: CGFloat = period == .week ? 4 : 2
        let now = Date()
        let pastTotals = bars.filter { $0.day <= now }.map(\.total)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text((period == .today ? "per hour" : "per day") + (chartIncludeCache ? " · incl. cache" : ""))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .help(chartIncludeCache
                        ? "Bars include prompt-cache reads and writes — the context each call actually processed. Turn off in Settings."
                        : "Bars show fresh input + output only (cache excluded). Turn on in Settings.")
                Spacer()
                // Plain-SwiftUI pills, NOT a segmented Picker or checkbox Toggle:
                // the AppKit-backed mini controls misreport their intrinsic width
                // in the MenuBarExtra popup and drew over each other ("Hide
                // weekends" under "Stacked") — and they render as placeholders in
                // snapshots, which is how the overlap escaped review. Same pill
                // pattern as the tab bar and session filter.
                if period != .today {
                    chartPill("Hide weekends", selected: hideWeekends,
                              help: "Drop Saturdays and Sundays from the chart") {
                        hideWeekends.toggle()
                    }
                }
                chartPill("Stacked", selected: barStyleRaw == "stacked",
                          help: "One bar per slot, providers stacked") {
                    barStyleRaw = "stacked"
                }
                chartPill("Grouped", selected: barStyleRaw == "grouped",
                          help: "Side-by-side mini-bars per provider") {
                    barStyleRaw = "grouped"
                }
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
            .padding(.top, 4)   // keep the tallest bar clear of the header pills
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
        let suffix = chartIncludeCache ? " (incl. cache)" : ""
        return "\(label): Claude \(Fmt.compact(d.claude)) · Codex \(Fmt.compact(d.codex)) · Ollama \(Fmt.compact(d.ollama)) · LM Studio \(Fmt.compact(d.lmStudio))\(suffix)"
    }

    private func leadingEdgeLabel(_ bars: [DayStat]) -> String {
        if period == .today { return "00:00" }
        guard let first = bars.first else { return "" }
        return Self.shortDayFmt.string(from: first.day)
    }

    // Shared bar tint: one opacity for all providers so stacked/grouped segments
    // read at equal weight. Colors come from the palette (single source of truth).
    private func barColor(_ o: UsageOrigin) -> Color { palette.color(o).opacity(0.9) }

    /// Segment heights: proportional with a 1.5pt visibility floor for every
    /// non-zero provider — but the floor's inflation is taken back out of the
    /// largest segment so the whole bar (plus its inter-segment spacing) can
    /// NEVER exceed the lane. Without the cap, a max-height day with all four
    /// providers drew ~47pt in a 42pt lane and rose into the header pills.
    private func stackedSegments(_ d: DayStat, maxV: Int, height: CGFloat) -> [(origin: UsageOrigin, height: CGFloat)] {
        let values: [(UsageOrigin, Int)] = [
            (.lmStudio, d.lmStudio), (.ollama, d.ollama),
            (.codex, d.codex), (.claudeCode, d.claude),
        ].filter { $0.1 > 0 }
        guard !values.isEmpty else { return [] }
        var heights = values.map { max(height * CGFloat($0.1) / CGFloat(maxV), 1.5) }
        let spacing = CGFloat(values.count - 1)   // VStack(spacing: 1)
        let excess = heights.reduce(0, +) + spacing - height
        if excess > 0, let tallest = heights.indices.max(by: { heights[$0] < heights[$1] }) {
            heights[tallest] = max(heights[tallest] - excess, 1.5)
        }
        return zip(values, heights).map { (origin: $0.0, height: $1) }
    }

    private func stackedBar(_ d: DayStat, maxV: Int, height: CGFloat) -> some View {
        VStack(spacing: 1) {
            ForEach(stackedSegments(d, maxV: maxV, height: height), id: \.origin) { segment in
                RoundedRectangle(cornerRadius: 1).fill(barColor(segment.origin))
                    .frame(height: segment.height)
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
                RoundedRectangle(cornerRadius: 1).fill(barColor(.claudeCode))
                    .frame(height: d.claude > 0 ? max(height * CGFloat(d.claude) / CGFloat(maxV), 1.5) : 0)
                RoundedRectangle(cornerRadius: 1).fill(barColor(.codex))
                    .frame(height: d.codex > 0 ? max(height * CGFloat(d.codex) / CGFloat(maxV), 1.5) : 0)
                RoundedRectangle(cornerRadius: 1).fill(barColor(.ollama))
                    .frame(height: d.ollama > 0 ? max(height * CGFloat(d.ollama) / CGFloat(maxV), 1.5) : 0)
                RoundedRectangle(cornerRadius: 1).fill(barColor(.lmStudio))
                    .frame(height: d.lmStudio > 0 ? max(height * CGFloat(d.lmStudio) / CGFloat(maxV), 1.5) : 0)
            }
        }
    }

    private func providerBlock(_ p: UsageOrigin) -> some View {
        let models = store.modelTotals(for: p, in: period)
        let shown = Array(models.prefix(5))
        return VStack(alignment: .leading, spacing: 3) {
            providerRow(p)
            ForEach(shown, id: \.model) { m in
                HStack(spacing: 6) {
                    Text(m.model).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(modelDetail(m.totals))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                }
                .padding(.leading, 17)
            }
            if models.count > shown.count {
                Text("+ \(models.count - shown.count) more models")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.leading, 17)
            }
        }
    }

    /// "1 call" / "2,054 calls" — locale grouping matches what SwiftUI's own
    /// integer interpolation produced before these strings were built by hand.
    private func calls(_ n: Int) -> String { n == 1 ? "1 call" : "\(n.formatted()) calls" }

    /// Per-model detail line. All-unmetered models (Ollama Desktop) say so
    /// instead of "↑ 0 ↓ 0"; mixed models carry the unmetered count so the
    /// token totals aren't silently read as covering every call.
    private func modelDetail(_ t: Totals) -> String {
        if t.unmetered == t.calls { return "no token data · \(calls(t.calls))" }
        let unmetered = t.unmetered > 0 ? " · \(t.unmetered) unmetered" : ""
        return "↑ \(Fmt.compact(t.input))  ↓ \(Fmt.compact(t.output))  · \(calls(t.calls))\(unmetered)"
    }

    /// Provider header, two lines: name + call count, then the metrics on their
    /// own indented line. The old single HStack (name + up to four metrics +
    /// calls) wrapped unpredictably once numbers got wide — "reasoning" broke
    /// mid-word, and the fixed 52pt name column split "LM Studio" in two.
    /// Giving metrics a full line and the name its natural width keeps every
    /// width stable regardless of magnitude.
    private func providerRow(_ p: UsageOrigin) -> some View {
        let t = store.totals(for: p, in: period)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                BrandMarkView(origin: p, size: 14)
                Text(p.displayName).font(.system(size: 12, weight: .medium)).fixedSize()
                Spacer()
                Text(t.calls == 0 ? "—" : calls(t.calls))
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
            if t.calls > 0 {
                HStack(spacing: 8) {
                    if t.unmetered == t.calls {
                        // Every call in this period is metadata-only (Ollama
                        // Desktop) — say so instead of fabricating "↑ 0 ↓ 0".
                        Text("tokens unavailable")
                            .foregroundStyle(.secondary)
                            .help("Ollama Desktop records its chats without runtime token counts, so these calls can only be counted, not metered. Route clients through the proxy for exact counts.")
                    } else {
                        Text("↑ \(Fmt.compact(t.input))").fixedSize()
                        if t.cacheRead > 0 {
                            Text("+\(Fmt.compact(t.cacheRead)) cache")
                                .foregroundStyle(.secondary).fixedSize()
                                .help("Prompt-cache reads: context re-served from cache on each call instead of resent as fresh input. Billed at ~10% of the input rate.")
                        }
                        Text("↓ \(Fmt.compact(t.output))").fixedSize()
                        if t.reasoning > 0 {
                            Text("· \(Fmt.compact(t.reasoning)) reasoning")
                                .foregroundStyle(.secondary).fixedSize()
                                .help("Reasoning tokens — a subset of output, already counted in ↓, shown here for detail.")
                        }
                        if t.unmetered > 0 {
                            Text("· \(t.unmetered) unmetered")
                                .foregroundStyle(.secondary).fixedSize()
                                .help("Calls observed without token counts (Ollama Desktop doesn't persist them). Included in the call count, absent from the token totals.")
                        }
                    }
                }
                .font(.system(size: 11.5)).monospacedDigit()
                .padding(.leading, 20)
            }
        }
    }

    @ViewBuilder private var sessionsContent: some View {
        let all = store.sessions(in: period)
        let filtered = sessionOriginFilter.origin.map { origin in
            all.filter { $0.provider == origin }
        } ?? all
        let sessions = Array(filtered.prefix(6))
        VStack(alignment: .leading, spacing: 5) {
            sessionOriginFilterBar
            if sessions.isEmpty {
                emptyNote(sessionOriginFilter == .all
                    ? "No sessions in this period"
                    : "No \(sessionOriginFilter.label) sessions in this period")
            }
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
            if filtered.count > sessions.count {
                Text("+ \(filtered.count - sessions.count) more sessions")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.leading, 14)
            }
        }
    }

    private var sessionOriginFilterBar: some View {
        HStack(spacing: 3) {
            ForEach(SessionOriginFilter.allCases) { filter in
                let selected = sessionOriginFilter == filter
                Button { sessionOriginFilterRaw = filter.rawValue } label: {
                    HStack(spacing: 4) {
                        if let origin = filter.origin {
                            BrandMarkView(origin: origin, size: 11)
                        }
                        Text(filter.label).font(.system(size: 10, weight: selected ? .semibold : .regular))
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .help(filter == .all ? "Show sessions from every local source" : "Show only \(filter.label) sessions")
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
        parts.append(calls(s.totals.calls))
        if s.totals.unmetered == s.totals.calls {
            // Metadata-only session (Ollama Desktop) — no fabricated "↑ 0 ↓ 0".
            parts.append("no token data")
        } else {
            parts.append("↑ \(Fmt.compact(s.totals.input))")
            if s.totals.cacheRead > 0 { parts.append("+\(Fmt.compact(s.totals.cacheRead)) cache") }
            parts.append("↓ \(Fmt.compact(s.totals.output))")
            if s.totals.reasoning > 0 { parts.append("\(Fmt.compact(s.totals.reasoning)) reasoning") }
        }
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
        let cells = store.heatmapDays(weeks: weeks, includeCache: chartIncludeCache)
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
                    ForEach(UsageOrigin.allCases, id: \.rawValue) { origin in
                        BrandMarkView(origin: origin, size: 11)
                        Text(origin.displayName).font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }
                    Text("· color mixes sources by share · more usage = stronger")
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
            .help(future ? "" : "\(Self.dayFmt.string(from: d.day)): \(Fmt.compact(d.total)) tokens (Claude \(Fmt.compact(d.claude)) · Codex \(Fmt.compact(d.codex)) · Ollama \(Fmt.compact(d.ollama)) · LM Studio \(Fmt.compact(d.lmStudio)))\(chartIncludeCache ? " · incl. cache" : "")")
    }

    private func heatColor(_ d: DayStat, _ maxV: Int) -> Color {
        guard d.total > 0 else { return Color.gray.opacity(0.18) }
        // Blend the (customizable) provider colors by that day's token share, so
        // mixed days read as a genuine mix rather than snapping to one hue. The
        // blend is perceptual (OKLab) with chroma restoration so near-complementary
        // pairs don't go grey; the tooltip still carries the exact breakdown.
        let t = Double(d.total)
        guard let base = palette.blend(claude: Double(d.claude) / t,
                                       codex: Double(d.codex) / t,
                                       ollama: Double(d.ollama) / t,
                                       lmStudio: Double(d.lmStudio) / t) else {
            return Color.gray.opacity(0.18)
        }
        // Opacity encodes total volume (more usage = stronger), orthogonal to hue.
        // sqrt lifts ordinary days out of the heavy-tailed distribution; the 0.32
        // floor keeps any nonzero day clearly above the empty-cell sentinel.
        let n = min(1, t / Double(maxV))
        return base.opacity(0.32 + 0.68 * n.squareRoot())
    }

    // MARK: - Settings tab

    // Grouped into three clusters — Sources (where each provider's data comes
    // from), Display (how it's shown), and Notifications — so related controls
    // sit together instead of the earlier scattered list.
    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            clusterHeader("Sources")
            claudeSourceGroup
            codexSourceGroup
            ollamaSourceGroup
            lmStudioSourceGroup

            clusterHeader("Display")
            menuBarGroup
            usageChartGroup
            providerColorsGroup
            showSectionsGroup

            clusterHeader("Notifications")
            notificationsGroup
        }
    }

    /// Bold label + trailing rule marking a top-level settings cluster.
    private func clusterHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            VStack { Divider() }
        }
        .padding(.top, 4)
    }

    // MARK: Sources

    private var claudeSourceGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Claude — plan limits")
            Text("Paste your claude.ai Cookie header to track session & weekly plan limits. At claude.ai/settings/usage: DevTools → Network, refresh, click the \"usage\" request, copy the full Cookie request header.")
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
                    .buttonStyle(.borderedProminent)
                    .font(.system(size: 11))
                    .disabled(cookieDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Stored locally in app preferences, sent only to claude.ai. Unofficial endpoint; may change.")
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // One Codex section: select the limits source. Local per-turn token tracking
    // remains active with either choice.
    private var codexSourceGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Codex")
            HStack(spacing: 3) {
                codexMethodButton("Cookie limits", "cookie", suffix: "· recommended")
                codexMethodButton("Local limits", "local", suffix: nil)
            }
            if codexUsesCookie { codexCookieConfig } else { codexLocalConfig }
        }
    }

    private func codexMethodButton(_ label: String, _ value: String, suffix: String?) -> some View {
        let selected = codexUsesCookie == (value == "cookie")
        return Button {
            codexSourceRaw = value
            // Switch only the limits source. The local Codex watcher continues
            // collecting per-turn token telemetry in either mode.
            if value == "cookie" {
                openAILimits.setMonitoring(false)   // stops local quota observation
                chatGPTLimits.start()               // starts the cookie poller (+refresh)
            } else {
                openAILimits.setMonitoring(true)    // starts local quota observation
                chatGPTLimits.stop()                // stops the cookie poller
            }
        } label: {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                if let suffix { Text(suffix).font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : .secondary)
        .help(value == "local"
              ? "Uses quota windows emitted by Codex on this Mac. Local session token tracking stays active with either limits source."
              : "Fetches account usage windows via the ChatGPT cookie. Local Codex session tokens are still tracked. Recommended.")
    }

    @ViewBuilder private var codexCookieConfig: some View {
        Text("Paste your chatgpt.com Cookie header to track session & weekly usage limits. At chatgpt.com: DevTools → Network, refresh, click the \"usage\" request, copy the full Cookie request header.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if chatGPTLimits.connected {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 11))
                Text("Connected").font(.system(size: 11.5))
                if let error = chatGPTLimits.errorMessage {
                    Text("· \(error)").font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
                }
                Spacer()
                Button("Disconnect") { chatGPTLimits.clearCookie() }.font(.system(size: 11))
            }
        }
        HStack(spacing: 6) {
            SecureField("Cookie header value…", text: $chatGPTCookieDraft)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
            Button("Save") { chatGPTLimits.setCookie(chatGPTCookieDraft); chatGPTCookieDraft = "" }
                .buttonStyle(.borderedProminent).font(.system(size: 11))
                .disabled(chatGPTCookieDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        Text("Stored locally in app preferences, sent only to chatgpt.com. Unofficial endpoint; may change.")
            .font(.system(size: 9.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text("Local Codex session tokens continue to be tracked from ~/.codex/sessions; this choice only changes the limits source.")
            .font(.system(size: 9.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var codexLocalConfig: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 11))
            Text("Active — reading local sessions").font(.system(size: 11.5))
        }
        Text("Reads only token_count telemetry in ~/.codex/sessions. Prompts, replies, and tool data are not stored by TokenScope.")
            .font(.system(size: 9.5)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10)).foregroundStyle(.orange)
            Text("Only updates while Codex is running on this Mac — it won't include ChatGPT/Codex usage from the web or other devices. Use the Cookie method for comprehensive, always-current tracking.")
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("Switch to the Cookie method above for comprehensive, always-current Codex tracking.")
    }


    private var ollamaSourceGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Ollama")
            Text("Tracks exact token usage for requests routed through TokenScope's proxy. Ollama Desktop bypasses that proxy, so TokenScope observes its completed-call metadata (model and duration) without reading message content; the app does not store token counts, so those calls are labeled unavailable.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            runtimeHealthRow(.ollama)
            HStack(spacing: 6) {
                Spacer()
                Button("Copy Ollama env") { copyEnv() }
                    .font(.system(size: 11))
                    .help("Copies the env vars that point Claude Code at Ollama through the proxy")
            }
        }
    }

    private var lmStudioSourceGroup: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("LM Studio")
            Text("Tracks completed LLM generations visible in LM Studio's shared model telemetry. Reads structured usage and timing fields only; prompts, replies, tool arguments, and raw error bodies are not retained.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            runtimeHealthRow(.lmStudio)
            if store.runtimeHealth[.lmStudio]?.state == .unavailable {
                Text("Install LM Studio and its command-line tool (lms) to enable tracking.")
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func runtimeHealthRow(_ provider: UsageOrigin) -> some View {
        let health = store.runtimeHealth[provider] ?? RuntimeHealth(provider: provider)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(runtimeHealthColor(health)).frame(width: 7, height: 7)
                Text(runtimeHealthLabel(health)).font(.system(size: 11.5))
                if let version = health.version, !version.isEmpty {
                    Text(runtimeVersionLabel(health.provider, version))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 5) {
                Text("Coverage: \(health.coverage)")
                if let last = health.lastEvent { Text("· last event \(when(last))") }
                else if let last = health.lastSuccess { Text("· checked \(when(last))") }
            }
            .font(.system(size: 9.5)).foregroundStyle(.secondary)
            if let error = health.lastError, !error.isEmpty {
                Text(error).font(.system(size: 9.5)).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    private func runtimeHealthColor(_ health: RuntimeHealth) -> Color {
        switch health.state {
        case .connected: return .green
        case .installed, .connecting, .degraded: return .orange
        case .unavailable: return .gray
        }
    }

    private func runtimeHealthLabel(_ health: RuntimeHealth) -> String {
        switch health.provider {
        case .ollama:
            if health.serverRunning && health.collectorRunning {
                return "Daemon reachable · proxy listening on \(store.proxyPort)"
            }
            if health.collectorRunning { return "Proxy listening · Ollama daemon unavailable" }
            if health.serverRunning { return "Daemon reachable · proxy unavailable" }
        case .lmStudio:
            if health.collectorRunning && health.serverRunning { return "Telemetry connected · API server running" }
            if health.collectorRunning { return "Telemetry connected · API server stopped" }
            if health.serverRunning { return "API server running · telemetry disconnected" }
        default: break
        }
        switch health.state {
        case .unavailable: return "Not available"
        case .installed: return "Installed · not connected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .degraded: return "Degraded"
        }
    }

    private func runtimeVersionLabel(_ provider: UsageOrigin, _ version: String) -> String {
        if provider == .lmStudio { return version }
        return version.lowercased().hasPrefix("v") ? version : "v\(version)"
    }

    // MARK: Display

    private var menuBarGroup: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Menu bar shows")
            Toggle(isOn: menuBarBinding("session")) {
                Text("Claude session limit %  ").font(.system(size: 11.5))
                + Text("(5h, needs claude.ai)").font(.system(size: 9.5)).foregroundColor(.secondary)
            }
            Toggle(isOn: menuBarBinding("weekly")) {
                Text("Claude weekly limit %  ").font(.system(size: 11.5))
                + Text("(7d, needs claude.ai)").font(.system(size: 9.5)).foregroundColor(.secondary)
            }
            Toggle(isOn: menuBarBinding("chatgptPrimary")) {
                Text("Codex session limit %  ").font(.system(size: 11.5))
                + Text("(5h)").font(.system(size: 9.5)).foregroundColor(.secondary)
            }
            Toggle(isOn: menuBarBinding("chatgptSecondary")) {
                Text("Codex weekly limit %  ").font(.system(size: 11.5))
                + Text("(7d)").font(.system(size: 9.5)).foregroundColor(.secondary)
            }
            Toggle(isOn: menuBarBinding("tokens")) {
                Text("Daily token count").font(.system(size: 11.5))
            }
            Text("Limit % is colored green / yellow / red by how close it is to the cap.")
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox).controlSize(.small)
    }

    private var usageChartGroup: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("Usage chart")
            Toggle("Include cached tokens in chart & heatmap", isOn: $chartIncludeCache)
                .font(.system(size: 11.5))
                .toggleStyle(.checkbox).controlSize(.small)
            Text("Cache reads/writes are context the model actually processed each call and usually dwarf fresh input. Off = fresh input + output only.")
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var providerColorsGroup: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                sectionTitle("Provider colors")
                Spacer()
                Button("Reset") { palette.resetAll(); hexDraft = [:] }
                    .font(.system(size: 11)).disabled(palette.isDefault)
            }
            ForEach(UsageOrigin.allCases, id: \.rawValue) { o in providerColorRow(o) }
            Text("Used for the brand marks, the Usage bar chart, the History heatmap (mixed-usage days blend these by token share), and the menu-bar gauges. Tap a swatch or type a hex code.")
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func providerColorRow(_ o: UsageOrigin) -> some View {
        HStack(spacing: 6) {
            BrandMarkView(origin: o, size: 15)
            Text(o.displayName).font(.system(size: 11.5)).frame(width: 44, alignment: .leading)
            ForEach(Self.presetSwatches, id: \.self) { hex in swatchButton(hex, for: o) }
            Spacer(minLength: 6)
            TextField("#RRGGBB", text: hexBinding(o))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 76)
                .onSubmit { commitHex(o) }
        }
    }

    private func swatchButton(_ hex: String, for o: UsageOrigin) -> some View {
        let c = ProviderPalette.color(fromHex: hex) ?? .gray
        let selected = ProviderPalette.hex(fromColor: palette.color(o)).caseInsensitiveCompare(hex) == .orderedSame
        return Button {
            palette.setColor(c, for: o)
            hexDraft[o.rawValue] = hex.uppercased()
        } label: {
            Circle().fill(c).frame(width: 15, height: 15)
                .overlay(Circle().strokeBorder(selected ? Color.primary : Color.primary.opacity(0.2),
                                               lineWidth: selected ? 2 : 0.5))
        }
        .buttonStyle(.plain).help(hex)
    }

    private var showSectionsGroup: some View {
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

    // MARK: Notifications

    private var notificationsGroup: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("Claude limit thresholds — session 25/50/75/90%, weekly 50/75/90%",
                   isOn: Binding(get: { limits.notificationsEnabled }, set: { limits.setNotifications($0) }))
            Toggle("Codex limit thresholds — session 25/50/75/90%, weekly 50/75/90%",
                   isOn: Binding(get: { openAILimits.notificationsEnabled }, set: { openAILimits.setNotifications($0) }))
            Toggle("Anthropic service status changes",
                   isOn: Binding(get: { status.notificationsEnabled }, set: { status.setNotifications($0) }))
            Toggle("OpenAI service status changes",
                   isOn: Binding(get: { openAIStatus.notificationsEnabled }, set: { openAIStatus.setNotifications($0) }))
        }
        .toggleStyle(.checkbox).controlSize(.small).font(.system(size: 11.5))
    }

    // A spread of presets so each provider can be set to a distinct hue with one
    // tap; the hex field covers any exact color. No NSColorPanel (which dismisses
    // the menu-bar popup), so this works inline.
    private static let presetSwatches = [
        "#F5942E", "#B052DE", "#5A9EFA", "#34C759", "#FF3B30", "#FF2D80", "#30C7C0",
    ]

    private func menuBarBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { listContains(menuBarItemsRaw, id) }, set: { _ in toggleInList(&menuBarItemsRaw, id) })
    }

    private func hexBinding(_ o: UsageOrigin) -> Binding<String> {
        Binding(get: { hexDraft[o.rawValue] ?? ProviderPalette.hex(fromColor: palette.color(o)) },
                set: { hexDraft[o.rawValue] = $0 })
    }

    private func commitHex(_ o: UsageOrigin) {
        if let c = ProviderPalette.color(fromHex: hexDraft[o.rawValue] ?? "") {
            palette.setColor(c, for: o)
            hexDraft[o.rawValue] = ProviderPalette.hex(fromColor: c)   // normalize
        } else {
            hexDraft[o.rawValue] = ProviderPalette.hex(fromColor: palette.color(o))   // revert invalid
        }
    }

    private func tabFor(_ s: AppSection) -> Tab {
        switch s {
        case .live, .latest: return .now
        case .chart, .providers, .performance, .sessions: return .usage
        case .heatmap: return .history
        }
    }

    // MARK: - Footer (Claude + OpenAI status links)

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            serviceIssueRows(status)
            serviceIssueRows(openAIStatus)
            HStack(spacing: 6) {
                statusLink(status)
                statusLink(openAIStatus)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.system(size: 11))
            }
        }
    }

    @ViewBuilder
    private func serviceIssueRows(_ service: StatusManager) -> some View {
        if !service.incidents.isEmpty || !service.degraded.isEmpty {
            ForEach(service.incidents.prefix(2)) { inc in
                Text("⚠︎ \(service.service.displayName): \(inc.name)")
                    .font(.system(size: 10.5)).foregroundStyle(.orange).lineLimit(1)
            }
            ForEach(service.degraded.prefix(3)) { component in
                Text("• \(service.service.displayName) \(component.name): \(component.status.replacingOccurrences(of: "_", with: " "))")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// Each provider-status row opens its own public status page. NSWorkspace
    /// also works in headless snapshot paths (where the button is never tapped).
    private func statusLink(_ service: StatusManager) -> some View {
        Button {
            NSWorkspace.shared.open(service.service.statusURL)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(service.color).frame(width: 7, height: 7)
                Text(service.allOperational ? "\(service.service.displayName): operational" : service.summary)
                    .font(.system(size: 10.5)).lineLimit(1)
                Image(systemName: "arrow.up.forward").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(service.service.statusURL.host ?? "status page")")
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
