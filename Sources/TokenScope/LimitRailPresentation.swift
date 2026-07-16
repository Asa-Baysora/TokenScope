import Foundation

/// Pure presentation logic for the pinned limit rail. The UI supplies only
/// windows that actually exist; this layer orders them and identifies the
/// nearest cap without reserving provider-specific holes.
enum LimitRailProvider: String, Equatable {
    case codex
    case claude
}

enum LimitRailPeriod: String, Equatable {
    case primary
    case secondary
}

enum LimitSeverity: Equatable {
    case healthy
    case warning
    case danger

    init(utilization: Double) {
        if utilization < 60 { self = .healthy }
        else if utilization <= 85 { self = .warning }
        else { self = .danger }
    }
}

struct LimitRailReading: Identifiable, Equatable {
    let id: String
    let provider: LimitRailProvider
    let period: LimitRailPeriod
    let label: String
    let utilization: Double
    let resetsAt: Date?

    var severity: LimitSeverity { LimitSeverity(utilization: utilization) }
    var fraction: Double { min(max(utilization / 100, 0), 1) }
}

enum LimitRailPresentation {
    /// Codex comes first, then Claude; each provider's shorter/primary window
    /// comes first. Filtering before this call makes missing windows collapse
    /// naturally with no empty cells.
    static func ordered(_ readings: [LimitRailReading]) -> [LimitRailReading] {
        readings.sorted {
            let lhs = sortKey($0)
            let rhs = sortKey($1)
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
    }

    /// Ties intentionally keep the first display-ordered cell stable.
    static func nearestID(in readings: [LimitRailReading]) -> String? {
        ordered(readings).reduce(nil as LimitRailReading?) { best, candidate in
            guard let best else { return candidate }
            return candidate.utilization > best.utilization ? candidate : best
        }?.id
    }

    private static func sortKey(_ reading: LimitRailReading) -> Int {
        let provider = reading.provider == .codex ? 0 : 2
        let period = reading.period == .primary ? 0 : 1
        return provider + period
    }
}
