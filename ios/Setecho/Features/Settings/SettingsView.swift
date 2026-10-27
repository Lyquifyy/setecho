import SwiftUI

/// Settings (More menu): the values the check-in can't read from anywhere else.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared

    private let weekdays: [(Int, String)] = [(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")]

    var body: some View {
        @Bindable var settings = settings
        ScreenScaffold {
            LinkButton(title: "Done", chevron: .leading) { dismiss() }
            TitleBlock(title: "Settings", subtitle: "Only what the check-in can't read from Apple Health or the log.")
            SectionCard("Cardio protocol") {
                Text("Your coach's words, e.g. \"25 min LISS × 2 on rest days\".").font(.subheadline).secondaryText()
                SettingsField(placeholder: "Assigned cardio", text: $settings.cardioProtocol)
            }
            SectionCard("Show date") {
                Text("yyyy-mm-dd. Leave empty when not in prep (the form says N/A).").font(.subheadline).secondaryText()
                SettingsField(placeholder: "2027-01-23", text: $settings.showDate)
            }
            SectionCard("Training days") {
                Text("Days the program schedules lifting. A day with a Setecho session always counts.").font(.subheadline).secondaryText()
                HStack(spacing: Theme.Space.xs) {
                    ForEach(weekdays, id: \.0) { day, name in
                        let on = settings.trainingWeekdays.contains(day)
                        Button(name) {
                            if on { settings.trainingWeekdays.remove(day) } else { settings.trainingWeekdays.insert(day) }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(on ? Theme.surface : Theme.cobalt)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(on ? Theme.cobalt : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous).strokeBorder(Theme.cobalt, lineWidth: 1))
                    }
                }
            }
            SectionCard("Check-in") {
                Toggle("Current weight is the 7-day average", isOn: $settings.useSevenDayAverageWeight)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                CardDivider()
                Picker("Collage layout", selection: $settings.collageLayout) {
                    Text("2 × 2").tag(PhotoAlign.CollageLayout.grid2x2)
                    Text("1 × 4").tag(PhotoAlign.CollageLayout.strip1x4)
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

struct SettingsField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.body)
            .foregroundStyle(Theme.navy)
            .autocorrectionDisabled()
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: 44)
            .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }
}
