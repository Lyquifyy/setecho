import Charts
import SwiftUI
import UIKit

// History's view of the WhatsApp import (HANDOFF.md §9): trends across every check-in, the past
// check-ins themselves, and the coach's replies to them in his own words.

/// One body measure across check-ins: its latest value, a line, and the change since the first.
struct TrendRow: View {
    let series: HistoryTrends.Series

    var body: some View {
        let first = series.points[0], last = series.points[series.points.count - 1]
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            HStack(alignment: .firstTextBaseline) {
                Text(series.field.label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.navy)
                Spacer()
                Text(Format.number(last.value)).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.navy)
            }
            if series.points.count > 1 {
                let values = series.points.map(\.value)
                let low = values.min()!, high = values.max()!
                let pad = max((high - low) * 0.15, 0.5)
                Chart(series.points, id: \.date) { point in
                    LineMark(x: .value("Date", point.date), y: .value(series.field.label, point.value))
                        .foregroundStyle(Theme.navy)
                    PointMark(x: .value("Date", point.date), y: .value(series.field.label, point.value))
                        .foregroundStyle(Theme.navy)
                        .symbolSize(16)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: (low - pad)...(high + pad))
                .frame(height: 56)
                .accessibilityLabel("\(series.field.label): \(Format.number(first.value)) on \(Format.shortDate(first.date)), \(Format.number(last.value)) on \(Format.shortDate(last.date))")
                Text("\(HistoryTrends.delta(last.value - first.value)) since \(Format.shortDate(first.date)) · \(series.points.count) check-ins")
                    .font(.footnote).monospacedDigit().secondaryText()
            } else {
                Text("\(Format.shortDate(last.date)) · 1 check-in").font(.footnote).monospacedDigit().secondaryText()
            }
        }
    }
}

/// A check-in from the WhatsApp import: the date, its weight when he gave one, its photos.
struct PastCheckInRow: View {
    @Environment(Store.self) private var store
    let checkIn: PastCheckIn
    let open: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(Format.shortDate(checkIn.sentAt)).font(.body).monospacedDigit().foregroundStyle(Theme.navy)
                Text(detail).font(.footnote).monospacedDigit().secondaryText()
            }
            Spacer()
            Button("Open", systemImage: "doc.text", action: open).buttonStyle(.setechoTonal)
        }
    }

    private var detail: String {
        var parts: [String] = []
        let weight = store.currentTemplate?.fields.first { $0.source.key == .currentWeight }
        if let weight, let value = checkIn.answers[weight.id].flatMap(CheckInText.number) { parts.append(Format.number(value)) }
        parts.append("\(checkIn.answers.count) answers")
        if !checkIn.photoFiles.isEmpty { parts.append("\(checkIn.photoFiles.count) photos") }
        return parts.joined(separator: " · ")
    }
}

/// A past check-in, read-only: his answers in the coach's order, then the photos as sent.
struct PastCheckInView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let checkIn: PastCheckIn

    var body: some View {
        ScreenScaffold(onClose: { dismiss() }) {
            TitleBlock(eyebrow: "From WhatsApp · \(Format.shortDate(checkIn.sentAt))", title: "Check-in")
            SectionCard("Answers") {
                let fields = (store.currentTemplate?.orderedFields ?? []).filter { checkIn.answers[$0.id] != nil }
                ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                    if index > 0 { CardDivider() }
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text(field.label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.navy)
                        Text(checkIn.answers[field.id] ?? "").font(.subheadline).monospacedDigit().secondaryText().textSelection(.enabled)
                    }
                }
            }
            if !checkIn.photoFiles.isEmpty {
                SectionCard("Photos") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Space.xxs), count: 4), spacing: Theme.Space.xxs) {
                        ForEach(checkIn.photoFiles, id: \.self) { file in
                            Color.clear
                                .aspectRatio(3 / 4, contentMode: .fit)
                                .overlay {
                                    if let image = UIImage(contentsOfFile: store.mediaDirectory.appendingPathComponent(file).path) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    } else {
                                        Theme.cameraFill
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tag, style: .continuous))
                        }
                    }
                }
            }
        }
    }
}

/// The coach's replies after each past check-in, newest first, word for word. Read only: none of it
/// changes the plan (rule 12); replaying them through /coach/reply is the next step.
struct CoachTimelineCard: View {
    @Environment(Store.self) private var store
    @State private var showAll = false

    var body: some View {
        let history = store.chatHistory
        let groups = Dictionary(grouping: history.coachMessages) { $0.checkInId ?? "" }
        let checkIns = history.checkIns.filter { groups[$0.id] != nil }.sorted { $0.sentAt > $1.sentAt }
        let shown = showAll ? checkIns : Array(checkIns.prefix(4))
        SectionCard("Coach replies from WhatsApp", accessory: {
            if checkIns.count > 4 {
                Button(showAll ? "Fewer" : "All \(checkIns.count)", systemImage: showAll ? "chevron.up" : "chevron.down") {
                    withAnimation(.snappy(duration: 0.25)) { showAll.toggle() }
                }
                .buttonStyle(.setechoTonal)
            }
        }) {
            Text("Word for word, as sent. They haven't changed your plan.").font(.footnote).secondaryText()
            ForEach(shown) { checkIn in
                CardDivider()
                Text("After your \(Format.shortDate(checkIn.sentAt)) check-in").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.navy)
                ForEach(groups[checkIn.id] ?? []) { message in
                    CoachMessageRow(message: message)
                }
            }
        }
    }
}

/// One of his messages: the day, then his words, closed to six lines.
struct CoachMessageRow: View {
    let message: CoachMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(message.at.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                .font(.caption.weight(.semibold)).monospacedDigit().secondaryText()
            if message.text.isEmpty {
                Label("Voice note, not transcribed yet", systemImage: "waveform").font(.subheadline).secondaryText()
            } else {
                Text(message.text)
                    .font(.subheadline).foregroundStyle(Theme.navy)
                    .lineLimit(expanded ? nil : 6)
                    .textSelection(.enabled)
                    .onTapGesture { withAnimation(.snappy(duration: 0.25)) { expanded.toggle() } }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
