import AVFoundation
import SwiftUI

/// Settings (More menu): the values the check-in can't read from anywhere else, the session
/// switches, and the voice Setecho speaks with.
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
                Text("Your coach's words, e.g. \"25 min LISS × 2 on rest days\". A coach reply that changes cardio updates this.").font(.subheadline).secondaryText()
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
            SectionCard("Sessions") {
                Toggle("Coach's voice in sessions", isOn: $settings.coachVoiceInSessions)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                Text("His cues from a reply play once before that exercise, never during a set. Each cue has its own checkbox on the Coach reply screen.")
                    .font(.footnote).secondaryText()
                CardDivider()
                Toggle("Next-set suggestions", isOn: $settings.nextSetSuggestions)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                Text("Only with a rule your coach wrote and you confirmed. You decide each one, and he sees it in the check-in.")
                    .font(.footnote).secondaryText()
            }
            SectionCard("What you can load") {
                Text("The steps his rules round to: barbell and dumbbell plates, and your gym's machine stacks.").font(.subheadline).secondaryText()
                StepField(label: "Barbell", value: $settings.barbellStepLb)
                CardDivider()
                StepField(label: "Dumbbells", value: $settings.dumbbellStepLb)
                CardDivider()
                StepField(label: "Machines", value: $settings.machineStepLb)
            }
            SectionCard("Rehearsal and filming") {
                Text("Your own WhatsApp number, digits only, so a rehearsal can send to you and never to him.").font(.subheadline).secondaryText()
                SettingsField(placeholder: "1316…", text: $settings.ownWhatsAppNumber)
                CardDivider()
                Toggle("Filming mode", isOn: $settings.filmingMode)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                Text("Saves every line Setecho speaks and every answer as audio with one clock, plus captions, for the demo edit. Stays on the phone; export by AirDrop from History. No change to timing.")
                    .font(.footnote).secondaryText()
            }
            SectionCard("Voice") {
                Text("Your first name, for the spotter to use sparingly. It goes only in the line request.").font(.subheadline).secondaryText()
                SettingsField(placeholder: "First name", text: $settings.athleteFirstName)
                CardDivider()
                Text("One voice everywhere: sessions, check-in morning and the wrap-up. Never your coach's.").font(.subheadline).secondaryText()
                Picker("Voice", selection: $settings.voiceIdentifier) {
                    Text("Best installed (premium first)").tag("")
                    ForEach(AudioService.availableVoices(), id: \.identifier) { voice in
                        Text("\(voice.name) · \(qualityName(voice.quality))").tag(voice.identifier)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.cobalt)
                if !AudioService.hasNaturalVoice {
                    Text("No premium voice is installed. Download one in Settings → Accessibility → Spoken Content → Voices → English.")
                        .font(.footnote).secondaryText()
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


private func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
    switch quality {
    case .premium: "premium"
    case .enhanced: "enhanced"
    default: "standard"
    }
}


/// "Barbell   5 lb" with a stepper.
private struct StepField: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Theme.navy)
            Spacer()
            Stepper(value: $value, in: 1...50, step: 1) {
                Text(Format.load(value)).font(.subheadline).monospacedDigit().foregroundStyle(Theme.navy)
            }
            .tint(Theme.cobalt)
            .fixedSize()
        }
        .frame(minHeight: 44)
    }
}
