import AVFoundation
import SwiftUI

/// Settings (More menu): the values the check-in can't read from anywhere else, the session
/// switches, and the voice Setecho speaks with.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    @State private var showDiagnostics = false

    /// The show date is stored as "yyyy-mm-dd", empty when not in prep.
    private var inPrep: Binding<Bool> {
        Binding(get: { !settings.showDate.isEmpty },
                set: { settings.showDate = $0 ? DayKey.string(Calendar.current.date(byAdding: .weekOfYear, value: 12, to: .now) ?? .now) : "" })
    }

    private var showDay: Binding<Date> {
        Binding(get: { DayKey.date(settings.showDate) ?? .now }, set: { settings.showDate = DayKey.string($0) })
    }

    /// The reminder time is stored as "HH:mm".
    private var wakeTime: Binding<Date> {
        Binding(get: {
            let parts = settings.checkInWakeTime.split(separator: ":").compactMap { Int($0) }
            return Calendar.current.date(bySettingHour: parts.first ?? 6, minute: parts.count > 1 ? parts[1] : 30, second: 0, of: .now) ?? .now
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            settings.checkInWakeTime = String(format: "%02d:%02d", c.hour ?? 6, c.minute ?? 30)
        })
    }

    private let weekdays: [(Int, String)] = [(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")]

    var body: some View {
        @Bindable var settings = settings
        ScreenScaffold {
            LinkButton(title: "Done", chevron: .none) { dismiss() }
            TitleBlock(title: "Settings", subtitle: "Only what the check-in can't read from Apple Health or the log.")
            SectionCard("Cardio protocol") {
                Text("Your coach's words, e.g. \"25 min LISS × 2 on rest days\". A coach reply that changes cardio updates this.").font(.subheadline).secondaryText()
                SettingsField(placeholder: "Assigned cardio", text: $settings.cardioProtocol)
            }
            SectionCard("Show date") {
                Toggle("In prep for a show", isOn: inPrep)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                if inPrep.wrappedValue {
                    DatePicker("Show day", selection: showDay, in: Date.now..., displayedComponents: .date)
                        .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                } else {
                    Text("Weeks out goes to the coach as N/A.").font(.footnote).secondaryText()
                }
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
                DatePicker("Check-in morning reminder", selection: wakeTime, displayedComponents: .hourAndMinute)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                Text("On the due morning the check-in opens by itself the first time you open Setecho.").font(.footnote).secondaryText()
                CardDivider()
                Toggle("Current weight is the 7-day average", isOn: $settings.useSevenDayAverageWeight)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                CardDivider()
                Text("Your own WhatsApp number, digits only. A rehearsal sends to you, never to your coach.").font(.subheadline).secondaryText()
                SettingsField(placeholder: "Your number", text: $settings.ownWhatsAppNumber)
                    .keyboardType(.numberPad)
            }
            SectionCard("Sessions") {
                Toggle("Coach's voice in sessions", isOn: $settings.coachVoiceInSessions)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                Text("His cues from a reply play once before that exercise, never during a set.")
                    .font(.footnote).secondaryText()
                CardDivider()
                Toggle("Next-set suggestions", isOn: $settings.nextSetSuggestions)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                Text("Only with a rule your coach wrote and you confirmed. You decide each one, and he sees it in the check-in.")
                    .font(.footnote).secondaryText()
            }
            SectionCard("What you can load") {
                Text("The steps his rules round to.").font(.subheadline).secondaryText()
                StepField(label: "Barbell", value: $settings.barbellStepLb)
                CardDivider()
                StepField(label: "Dumbbells", value: $settings.dumbbellStepLb)
                CardDivider()
                StepField(label: "Machines", value: $settings.machineStepLb)
            }
            SectionCard("Voice") {
                Text("Your first name. Setecho uses it now and then.").font(.subheadline).secondaryText()
                SettingsField(placeholder: "First name", text: $settings.athleteFirstName)
                CardDivider()
                Toggle("Use AirPods mic", isOn: $settings.useAirPodsMic)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                Text(AirPodsMic.shared.notice ?? "Off: AirPods only play, and the DJI receiver or the iPhone mic listens. On: AirPods record at full quality where iOS 26 supports it; if they can only do call quality, Setecho switches back by itself.")
                    .font(.footnote).secondaryText()
                CardDivider()
                Text("The voice for sessions. In the check-in it only fills in when the natural voice is slow.").font(.subheadline).secondaryText()
                Picker("Voice", selection: $settings.voiceIdentifier) {
                    Text("Best installed").tag("")
                    ForEach(AudioService.availableVoices(), id: \.identifier) { voice in
                        Text("\(voice.name) · \(qualityName(voice.quality))").tag(voice.identifier)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.cobalt)
                if !AudioService.hasNaturalVoice {
                    Text("For a better session voice, download a premium one in Settings → Accessibility → Spoken Content → Voices.")
                        .font(.footnote).secondaryText()
                }
            }
            SectionCard("Behind the scenes") {
                Toggle("Filming mode", isOn: $settings.filmingMode)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                Text("Records every spoken line and answer for the demo video. Stays on the phone; AirDrop it from History.")
                    .font(.footnote).secondaryText()
                CardDivider()
                LinkButton(title: "Diagnostics") { showDiagnostics = true }
            }
        }
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack { ProbeHomeView() }.tint(Theme.cobalt)
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
