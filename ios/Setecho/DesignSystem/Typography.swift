import SwiftUI

/// Interface type is the system font (SF Pro). The serif wordmark is an image asset, never live text.
/// Every number a lifter reads (loads, reps, percentages, times) uses tabular digits so columns line up.
extension Font {
    /// "Bench press", "History", "Coach", "Set 3 saved"
    static let screenTitle = Font.system(.largeTitle, weight: .bold)
    /// Section titles inside cards: "Next set", "Completed sets"
    static let sectionTitle = Font.system(.headline, weight: .semibold)
    /// Coach headline: "Drop 5 lb for set 4."
    static let answerTitle = Font.system(.title3, weight: .bold)
    /// Table column labels: "SET", "LOAD", "REPS"
    static let columnLabel = Font.system(.caption, weight: .semibold)

    /// Large load/rep numbers in cards. Fixed size on purpose; wrap the view in ViewThatFits if space is tight.
    static let metricXL = Font.system(size: 44, weight: .bold).monospacedDigit()
    static let metricL = Font.system(size: 36, weight: .bold).monospacedDigit()
    static let metricUnitXL = Font.system(size: 24, weight: .semibold)
    static let metricUnitL = Font.system(size: 20, weight: .semibold)
}

extension View {
    /// Navy, sentence-case screen title with tight tracking.
    func screenTitleStyle() -> some View {
        font(.screenTitle).tracking(-0.4).foregroundStyle(Theme.navy)
    }

    func secondaryText() -> some View {
        foregroundStyle(Theme.textSecondary)
    }
}
