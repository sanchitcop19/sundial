import Foundation

/// Calendar periods for statistics, always anchored to the period containing now.
public enum StatsPeriod: String, CaseIterable, Sendable {
    case week, month, quarter, year

    public var title: String {
        switch self {
        case .week: return "This week"
        case .month: return "This month"
        case .quarter: return "This quarter"
        case .year: return "This year"
        }
    }

    /// Work weeks begin on Monday, in the user's current calendar and timezone.
    /// Callers can supply a different calendar, including its first weekday.
    public static var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    /// The entire containing period. Statistics include only its elapsed portion.
    public func interval(containing now: Date,
                         calendar: Calendar = StatsPeriod.calendar) -> DateInterval {
        let component: Calendar.Component
        switch self {
        case .week: component = .weekOfYear
        case .month: component = .month
        case .quarter: component = .quarter
        case .year: component = .year
        }
        return calendar.dateInterval(of: component, for: now)!
    }
}
