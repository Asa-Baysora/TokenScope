import Foundation

/// Provider-neutral operational summary. Keeping this outside SwiftUI makes the
/// parity contract testable: every local runtime is reduced with the same rules.
struct ProviderPerformanceSummary: Identifiable, Equatable {
    var id: UsageOrigin { provider }
    let provider: UsageOrigin
    let calls: Int
    let succeeded: Int
    let failed: Int
    let cancelled: Int
    let estimated: Int
    let unknownTokens: Int
    let medianTokensPerSecond: Double?
    let medianTimeToFirstTokenSeconds: Double?
    let medianDurationSeconds: Double?
}

enum PerformanceAggregator {
    static func summarize(
        _ events: [UsageEvent],
        providers: [UsageOrigin] = [.ollama, .lmStudio]
    ) -> [ProviderPerformanceSummary] {
        providers.compactMap { provider in
            let calls = events.filter { $0.provider == provider && !$0.shadowed }
            guard !calls.isEmpty else { return nil }
            return ProviderPerformanceSummary(
                provider: provider,
                calls: calls.count,
                succeeded: calls.filter { $0.status == .succeeded }.count,
                failed: calls.filter { $0.status == .failed }.count,
                cancelled: calls.filter { $0.status == .cancelled }.count,
                estimated: calls.filter { $0.tokenAccuracy == .estimated }.count,
                unknownTokens: calls.filter { $0.tokenAccuracy == .unknown }.count,
                medianTokensPerSecond: median(calls.compactMap(\.tokensPerSecond)),
                medianTimeToFirstTokenSeconds: median(calls.compactMap(\.timeToFirstTokenSeconds)),
                medianDurationSeconds: median(calls.compactMap(\.durationSeconds))
            )
        }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
