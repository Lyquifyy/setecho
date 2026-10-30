import AVFoundation
import SwiftUI

/// Settings (More menu), top to bottom: about you, training, the check-in, sessions, the voice
/// Setecho speaks with, and last, behind a switch, Developer (rehearsal, filming, data, probes).
/// Every row is the control first and a `Note` under it; the X in the header closes the sheet.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.shared
    @State private var personalVoiceNote: String?
    @ScaledMetric(relativeTo: .subheadline) private var weekdayWidth = Theme.Control.minimum
    @State private var showGuide = false
    @State private var showIntro = false

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
        ScreenScaffold(onClose: { dismiss() }) {
            TitleBlock(title: "Make it yours", subtitle: "Your routine, your voice, your preferences.")

            SectionCard("You") {
                SettingsField(placeholder: "First name", text: $settings.athleteFirstName)
                    .textContentType(.givenName)
                Note("Setecho uses your first name now and then.")
                CardDivider()
                SettingToggle("Preparing for a competition", isOn: inPrep)
                if inPrep.wrappedValue {
                    DatePicker("Competition date", selection: showDay, in: Date.now..., displayedComponents: .date)
                        .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                } else {
                    Note("Weeks until the competition is sent to your coach as N/A.")
                }
            }

            SectionCard("Training") {
                RowLabel("Training days")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: weekdayWidth), spacing: Theme.Space.xxs / 2)], spacing: Theme.Space.xs) {
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
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                Note("The days your program schedules lifting. A day with a Setecho session always counts.")
                CardDivider()
                RowLabel("Cardio")
                SettingsField(placeholder: "e.g. 25 min LISS × 2 on rest days", text: $settings.cardioProtocol)
                Note("In your coach's words. A coach reply that changes cardio updates this.")
                CardDivider()
                RowLabel("Load steps")
                StepField(label: "Barbell", value: $settings.barbellStepLb)
                StepField(label: "Dumbbells", value: $settings.dumbbellStepLb)
                StepField(label: "Machines", value: $settings.machineStepLb)
                Note("The smallest jump you can make on each. His rules round to these.")
            }

            SectionCard("Check-in") {
                DatePicker("Morning reminder", selection: wakeTime, displayedComponents: .hourAndMinute)
                    .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
                Note("On the due morning the check-in opens by itself the first time you open Setecho.")
                CardDivider()
                SettingToggle("Current weight is the 7-day average", isOn: $settings.useSevenDayAverageWeight)
                Note("Off: your latest weigh-in.")
            }

            SectionCard("Sessions") {
                SettingToggle("Coach's voice in sessions", isOn: $settings.coachVoiceInSessions)
                Note("His cues from a reply play once before that exercise, never during a set.")
                CardDivider()
                SettingToggle("Next-set suggestions", isOn: $settings.nextSetSuggestions)
                Note("Only with a rule your coach wrote and you confirmed. You decide each one, and he sees it in the check-in.")
                CardDivider()
                SettingToggle("Talkative spotter", isOn: $settings.talkativeSpotter)
                Note("Talks like a training partner between sets, with a word on each set against last time. Never during a set, and every number is from your log.")
                CardDivider()
                SettingToggle("Start holds automatically", isOn: $settings.autoStartHolds)
                Note("Off: a hold starts when you say \u{201C}go\u{201D}, after \u{201C}three, two, one\u{201D}. On: the next one starts itself when its rest is up.")
                CardDivider()
                SettingToggle("Machine-taken help", isOn: $settings.machineTakenHelp)
                Note("When you say a machine's taken, his choices in the order you confirmed. Off: your own swaps (\u{201C}doing dumbbells instead\u{201D}) still work, and he still sees them.")
                CardDivider()
                SettingToggle("Start sets from the camera", isOn: $settings.cameraStartsSets)
                Note("For an empty home gym: any movement in frame starts a set. Off: say \u{201C}go\u{201D} when you lift, and the camera follows only you.")
                CardDivider()
                SettingToggle("Camera faces you", isOn: $settings.frontCameraInSessions)
                Note("The front camera, so the screen faces you from the bench. Off: the back camera, as before.")
                CardDivider()
                SettingToggle("Use AirPods mic", isOn: $settings.useAirPodsMic)
                Note(AirPodsMic.shared.notice ?? "On: AirPods that record at full quality (iOS 26 high-quality recording) listen as well as play, and your music keeps playing at full quality. AirPods that can't stay as headphones and the iPhone mic listens; Setecho never switches them to call quality. A plugged-in mic always wins. Off: the iPhone mic listens.")
                CardDivider()
                LinkButton(title: "How a session works") { showIntro = true }
                LinkButton(title: "What you can say") { showGuide = true }
                Note("Between sets, \u{201C}what can I say?\u{201D} tells you what works right then.")
            }

            SectionCard("Voice") {
                HStack {
                    Text("Voice").font(.subheadline).foregroundStyle(Theme.navy)
                    Spacer(minLength: Theme.Space.s)
                    Picker("Voice", selection: $settings.voiceIdentifier) {
                        Text(AudioService.defaultVoice.map { "Default · \($0.name) (\(qualityName($0.quality)))" } ?? "Best installed").tag("")
                        ForEach(AudioService.availableVoices(), id: \.identifier) { voice in
                            Text("\(voice.name) · \(AudioService.qualityLabel(voice).lowercased())").tag(voice.identifier)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .tint(Theme.cobalt)
                }
                .frame(minHeight: 44)
                Note(AudioService.defaultVoice == nil
                     ? "The voice Setecho speaks with, everywhere. For the best one, download Ava (Premium): Settings → Accessibility → Read & Speak → Voices → English."
                     : "The voice Setecho speaks with, everywhere.")
                CardDivider()
                SettingToggle("Use my Personal Voice", isOn: Binding(get: { usingPersonalVoice }, set: { on in Task { await usePersonalVoice(on) } }))
                Note(personalVoiceNote ?? "Your own voice, made on this iPhone in Settings → Accessibility → Personal Voice. It runs on the phone like the others.")
            }

            SectionCard("Voice tone", accessory: {
                LinkButton(title: "Reset", chevron: .none) { settings.setTone(VoiceTone(), for: AudioService.currentVoiceId) }
            }) {
                Note("For \(AudioService.voiceDescription). Saved for this voice.")
                ToneSlider(label: "Speed", value: tone(\.rate), range: SpokenText.rateRange, step: 0.01, format: "%.2f")
                ToneSlider(label: "Pitch", value: tone(\.pitch), range: VoiceTone.pitchRange, step: 0.01, format: "%.2f")
                ToneSlider(label: "Warmth", value: tone(\.warmthDB), range: VoiceTone.warmthRange, step: 0.5, format: "%+.1f dB")
                ToneSlider(label: "Clarity", value: tone(\.clarityDB), range: VoiceTone.clarityRange, step: 0.5, format: "%+.1f dB")
                Button("Play sample", systemImage: "play.fill") { VoiceSample.play() }
                    .buttonStyle(.setechoOutline)
            }

            SectionCard("Developer") {
                SettingToggle("Developer tools", isOn: $settings.developerTools)
                Note("Rehearsals, filming, session data and the phone probes. Off for everyday use.")
                if settings.developerTools {
                    CardDivider()
                    NavigationLink {
                        DeveloperView(onClose: { dismiss() })
                    } label: {
                        HStack(spacing: Theme.Space.xxs) {
                            Text("Open developer tools")
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.cobalt)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            // Which build is on the phone, so a test can be matched to its TestFlight upload.
            Text(Self.buildLine)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
        }
        .sheet(isPresented: $showGuide) { VoiceGuideView() }
        .sheet(isPresented: $showIntro) { SessionIntroView() }
    }

    /// "Setecho 1.0 · build 202610290738"
    static var buildLine: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Setecho \(version) · build \(build)"
    }

    /// One part of the current voice's tone, saved per voice as it moves.
    private func tone(_ key: WritableKeyPath<VoiceTone, Double>) -> Binding<Double> {
        Binding(get: { settings.tone(for: AudioService.currentVoiceId)[keyPath: key] },
                set: { value in
                    var tone = settings.tone(for: AudioService.currentVoiceId)
                    tone[keyPath: key] = value
                    settings.setTone(tone, for: AudioService.currentVoiceId)
                })
    }

    private var usingPersonalVoice: Bool {
        AudioService.personalVoices.contains { $0.identifier == settings.voiceIdentifier }
    }

    /// On: ask iOS for permission once, then speak with his Personal Voice everywhere. Off: back to the default.
    private func usePersonalVoice(_ on: Bool) async {
        guard on else {
            settings.voiceIdentifier = ""
            personalVoiceNote = nil
            return
        }
        let status = AudioService.personalVoiceStatus == .authorized ? .authorized : await AudioService.requestPersonalVoice()
        switch status {
        case .authorized:
            if let voice = AudioService.personalVoices.first {
                settings.voiceIdentifier = voice.identifier
                personalVoiceNote = "Speaking as \(voice.name). Tap Play sample to hear it."
            } else {
                personalVoiceNote = "No Personal Voice on this iPhone yet. Make one in Settings → Accessibility → Personal Voice, then turn this on again."
            }
        case .denied:
            personalVoiceNote = "Setecho isn't allowed to use it. Turn on \"Allow Apps to Request to Use\" in Settings → Accessibility → Personal Voice, then try again."
        case .unsupported:
            personalVoiceNote = "This iPhone can't use a Personal Voice."
        default:
            personalVoiceNote = "Personal Voice isn't ready yet. Try again in a moment."
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


/// A setting's switch: its name in navy, the cobalt switch, and a `Note` under it saying what it does.
private struct SettingToggle: View {
    let title: String
    @Binding var isOn: Bool

    init(_ title: String, isOn: Binding<Bool>) {
        self.title = title
        self._isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
            .tint(Theme.cobalt).font(.subheadline).foregroundStyle(Theme.navy)
            .frame(minHeight: 44)
    }
}

/// The name above a group of controls in a card: "Training days", "Load steps".
private struct RowLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.navy)
    }
}

/// The line under a setting saying what it does, always below the control it explains.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.footnote).secondaryText().fixedSize(horizontal: false, vertical: true)
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

/// "Play sample": one check-in line in the chosen voice and tone, through the same chain as every line.
@MainActor
private enum VoiceSample {
    static let output = VoiceOutput()

    static func play() {
        output.cancel()
        let tone = AudioService.currentTone
        let line = "Apple Health has you at 180.8. Should I use that?"
        Task { await output.speak(SpokenText.utterance(line, voice: AudioService.preferredVoice(), tone: tone), tone: tone) }
    }
}

/// A labelled slider with its value: "Warmth  +2.0 dB".
private struct ToneSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        VStack(spacing: Theme.Space.xxs) {
            HStack {
                Text(label).font(.subheadline).foregroundStyle(Theme.navy)
                Spacer()
                Text(String(format: format, value)).font(.subheadline).monospacedDigit().secondaryText()
            }
            Slider(value: $value, in: range, step: step).tint(Theme.cobalt)
        }
    }
}

