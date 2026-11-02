import Compression
import Foundation
import Testing
@testable import Setecho

/// The WhatsApp history import (HANDOFF.md §9) on synthetic exports written by hand: no real chat,
/// person, number or photo. Both date formats, multi-line messages, media lines, the check-in read
/// through the form, photos linked by time, the coach's replies, and dedupe on re-import.
private func template() throws -> CheckInTemplate {
    let url = try #require(SampleCoach.url("template"))
    return try JSONCoding.decoder.decode(CheckInTemplate.self, from: Data(contentsOf: url))
}

private let chicago = TimeZone(identifier: "America/Chicago")!

private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = chicago
    return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

/// An iPhone export in US style: a system line, a check-in over two messages with a multi-line
/// answer, four photos, his replies (text and a voice note), chit-chat, an omitted image, an edited
/// message, a late question from the coach and a stray photo.
private let usExport = """
[9/28/26, 8:01:12\u{202F}AM] Coach: \u{200E}Messages and calls are end-to-end encrypted. No one outside of this chat, not even WhatsApp, can read or listen to them.
[10/1/26, 7:40:02\u{202F}AM] Athlete: Morning! Check-in below
[10/1/26, 7:41:30\u{202F}AM] Athlete: Accuracy on plan (%): 95%, missed one meal Saturday
*Current body weight:* 182.6 lbs
Last check-in body weight: 183.4
Waist measurement (inches): 33.0
Bicep measurement, flexed (inches): 15.5
Thigh measurement, flexed - 24
Fasted blood glucose: 92
Energy levels (scale 1-10): 7/10, solid week
Biggest win this week: Hit 10 reps on incline
at 185 for the first time

Additional notes or concerns: none
\u{200E}[10/1/26, 7:42:05\u{202F}AM] Athlete: \u{200E}<attached: 00000003-PHOTO-2026-10-01-07-42-05.jpg>
\u{200E}[10/1/26, 7:42:06\u{202F}AM] Athlete: \u{200E}<attached: 00000004-PHOTO-2026-10-01-07-42-06.jpg>
\u{200E}[10/1/26, 7:42:07\u{202F}AM] Athlete: \u{200E}<attached: 00000005-PHOTO-2026-10-01-07-42-07.jpg>
\u{200E}[10/1/26, 7:42:08\u{202F}AM] Athlete: \u{200E}<attached: 00000006-PHOTO-2026-10-01-07-42-08.jpg>
[10/1/26, 6:15:00\u{202F}PM] Coach: Great week. Keep everything the same.
Drop carbs by 25 on rest days.
\u{200E}[10/2/26, 9:00:00\u{202F}AM] Coach: \u{200E}<attached: 00000008-AUDIO-2026-10-02-09-00-00.opus>
[10/3/26, 12:30:00\u{202F}PM] Athlete: how was your weekend
\u{200E}[10/3/26, 12:31:00\u{202F}PM] Coach: \u{200E}image omitted
[10/8/26, 7:35:10\u{202F}AM] Athlete: Current body weight: 181.8
Waist measurement (inches): 32.5
Fasted blood glucose: 90
Energy levels (scale 1-10): 8/10
\u{200E}[10/8/26, 7:36:00\u{202F}AM] Athlete: \u{200E}<attached: 00000010-PHOTO-2026-10-08-07-36-00.jpg>
[10/8/26, 9:10:00\u{202F}AM] Coach: Nice. Same plan this week. \u{200E}<This message was edited>
[10/14/26, 3:00:00\u{202F}PM] Coach: How's the knee holding up?
\u{200E}[10/14/26, 8:00:00\u{202F}PM] Athlete: \u{200E}<attached: 00000012-PHOTO-2026-10-14-20-00-00.jpg>
"""

/// The same chat style with the phone set to ISO dates and a 24-hour clock.
private let isoExport = """
[2026-10-19, 07:42:11] Athlete: Current body weight: 180.4
Waist measurement (inches): 32.0
Fasted blood glucose: 88
[2026-10-19, 07:43:00] Athlete: \u{200E}<attached: 00000020-PHOTO-2026-10-19-07-43-00.jpg>
[2026-10-19, 19:05:40] Coach: Down again, good.
"""

/// Android's export: day first, a dash after the time, "(file attached)" and "<Media omitted>".
private let androidExport = """
19/10/2026, 07:42 - Athlete: Current body weight: 180.4
Waist measurement (inches): 32.0
Fasted blood glucose: 88
19/10/2026, 07:43 - Athlete: IMG-20261019-WA0003.jpg (file attached)
19/10/2026, 07:44 - Athlete: <Media omitted>
19/10/2026, 20:15 - Coach: Hold steady.
"""

// MARK: Parsing

@Test func parsesTheUSExportWithMultiLineMessagesAndMedia() {
    let messages = WhatsAppChat.parse(usExport, timeZone: chicago)
    // The encryption notice is WhatsApp's line, not anyone's message.
    #expect(messages.count == 15)
    #expect(messages.first?.text == "Morning! Check-in below")
    let checkIn = messages[1]
    #expect(checkIn.sender == "Athlete")
    #expect(checkIn.at == date(2026, 10, 1, 7, 41, 30))
    #expect(checkIn.text.hasPrefix("Accuracy on plan (%): 95%"))
    #expect(checkIn.text.contains("at 185 for the first time\n\nAdditional notes or concerns: none"))

    let photo = messages[2]
    #expect(photo.attachment == "00000003-PHOTO-2026-10-01-07-42-05.jpg" && photo.text.isEmpty && photo.attachmentKind == .photo)
    let reply = messages[6]
    #expect(reply.at == date(2026, 10, 1, 18, 15))
    #expect(reply.text == "Great week. Keep everything the same.\nDrop carbs by 25 on rest days.")
    #expect(messages[7].attachmentKind == .audio)
    let omitted = messages[9]
    #expect(omitted.sender == "Coach" && omitted.mediaOmitted && omitted.attachment == nil && omitted.text.isEmpty)
    #expect(messages[12].text == "Nice. Same plan this week.")
}

@Test func parsesISODatesAndTheTwentyFourHourClock() {
    let messages = WhatsAppChat.parse(isoExport, timeZone: chicago)
    #expect(messages.count == 3)
    #expect(messages[0].at == date(2026, 10, 19, 7, 42, 11))
    #expect(messages[0].text == "Current body weight: 180.4\nWaist measurement (inches): 32.0\nFasted blood glucose: 88")
    #expect(messages[2].at == date(2026, 10, 19, 19, 5, 40))
}

@Test func parsesAndroidDayFirstExports() {
    let messages = WhatsAppChat.parse(androidExport, timeZone: chicago)
    #expect(messages.count == 4)
    #expect(messages[0].at == date(2026, 10, 19, 7, 42))
    #expect(messages[1].attachment == "IMG-20261019-WA0003.jpg")
    #expect(messages[2].mediaOmitted)
    #expect(messages[3].at == date(2026, 10, 19, 20, 15))
}

@Test func monthFirstUnlessADayGivesItAway() {
    let us = WhatsAppChat.parse("[3/4/26, 9:00 AM] A: hi", timeZone: chicago)
    #expect(us.first?.at == date(2026, 3, 4, 9, 0))
    let dayFirst = WhatsAppChat.parse("[3/4/26, 9:00 AM] A: hi\n[25/4/26, 12:00 AM] A: later", timeZone: chicago)
    #expect(dayFirst.map(\.at) == [date(2026, 4, 3, 9, 0), date(2026, 4, 25, 0, 0)])
}

@Test func messageKeysFollowTimestampSenderAndText() {
    let a = ChatMessage(at: date(2026, 10, 1, 7, 0), sender: "Athlete", text: "hi")
    #expect(a.key == ChatMessage(at: date(2026, 10, 1, 7, 0), sender: "Athlete", text: "hi").key)
    #expect(a.key != ChatMessage(at: date(2026, 10, 1, 7, 0), sender: "Coach", text: "hi").key)
    #expect(a.key != ChatMessage(at: date(2026, 10, 1, 7, 0), sender: "Athlete", text: "hi!").key)
    let photo = ChatMessage(at: a.at, sender: "Athlete", text: "", attachment: "1.jpg")
    #expect(photo.key != ChatMessage(at: a.at, sender: "Athlete", text: "", attachment: "2.jpg").key)
}

// MARK: The check-in through the form

@Test func readsACheckInIntoTheFormsFields() throws {
    let messages = WhatsAppChat.parse(usExport, timeZone: chicago)
    let answers = CheckInText.answers(in: messages[1].text, template: try template())
    #expect(answers["accuracy_on_plan"] == "95%, missed one meal Saturday")
    #expect(answers["current_body_weight"] == "182.6 lbs")
    #expect(answers["last_check_in_body_weight"] == "183.4")
    #expect(answers["waist_measurement"] == "33.0")
    #expect(answers["bicep_measurement_flexed"] == "15.5")
    #expect(answers["thigh_measurement_flexed"] == "24")
    #expect(answers["fasted_blood_glucose"] == "92")
    #expect(answers["energy_levels"] == "7/10, solid week")
    #expect(answers["biggest_win_this_week"] == "Hit 10 reps on incline\nat 185 for the first time")
    #expect(answers["additional_notes_or_concerns"] == "none")
    #expect(answers.count == 10)
    #expect(CheckInText.number(in: answers["current_body_weight"]!) == 182.6)
    #expect(CheckInText.number(in: "10,412 a day") == 10412)
    #expect(CheckInText.number(in: "none") == nil)
}

@Test func aLabelOnlyOpensALineAsAWholePhrase() throws {
    let t = try template()
    // "Notes on sleepiness" isn't "Notes on sleep"; a label mid-sentence isn't a field.
    #expect(CheckInText.answers(in: "Notes on sleepiness: lots", template: t).isEmpty)
    #expect(CheckInText.answers(in: "My current body weight is 180", template: t).isEmpty)
    #expect(CheckInText.answers(in: "Notes on sleep\nSlept 8 hours most nights", template: t) == ["notes_on_sleep": "Slept 8 hours most nights"])
}

// MARK: Sorting the chat

@Test func classifiesCheckInsPhotosAndCoachReplies() throws {
    let messages = WhatsAppChat.parse(usExport, timeZone: chicago)
    let result = ChatImport.classify(messages, athlete: "Athlete", coach: "Coach", template: try template())
    #expect(result.checkIns.count == 2)
    let first = result.checkIns[0], second = result.checkIns[1]
    #expect(first.sentAt == date(2026, 10, 1, 7, 41, 30))
    #expect(first.photoFiles == (3...6).map { "whatsapp/0000000\($0)-PHOTO-2026-10-01-07-42-0\($0 + 2).jpg" })
    #expect(second.answers["current_body_weight"] == "181.8" && second.answers.count == 4)
    #expect(second.photoFiles == ["whatsapp/00000010-PHOTO-2026-10-08-07-36-00.jpg"])

    // His replies: the text and the voice note after the first, the edited one after the second.
    // The omitted image, the chit-chat and his question six days later are dropped.
    #expect(result.coachMessages.map(\.checkInId) == [first.id, first.id, second.id])
    #expect(result.coachMessages[0].text == "Great week. Keep everything the same.\nDrop carbs by 25 on rest days.")
    #expect(result.coachMessages[1].audioFile == "whatsapp/00000008-AUDIO-2026-10-02-09-00-00.opus" && result.coachMessages[1].text.isEmpty)
    #expect(!result.coachMessages.contains { $0.text.contains("knee") })
    // Kept: 2 check-in messages, 5 photos, 3 replies. The stray photo is far from any check-in.
    #expect(result.kept.count == 10 && result.dropped == 5)
    #expect(!result.files.contains { $0.contains("00000012") })
}

@Test func styleExamplesAreHisLinesWithNumbersBlanked() throws {
    let t = try template()
    let result = ChatImport.classify(WhatsAppChat.parse(usExport, timeZone: chicago), athlete: "Athlete", coach: "Coach", template: t)
    let examples = ChatImport.styleExamples(result.checkIns, template: t)
    #expect(examples.contains("Energy levels (scale 1-10): X/X, solid week"))
    #expect(examples.contains("Biggest win this week: Hit X reps on incline at X for the first time"))
    // Numbers in his answers never reach the agent; the measurement fields aren't style.
    #expect(examples.allSatisfy { line in !line.split(separator: ":", maxSplits: 1).last!.contains(where: \.isNumber) })
    #expect(!examples.contains { $0.hasPrefix("Current body weight") })
}

@Test func trendsJoinPastAndSentCheckInsOncePerDay() throws {
    let t = try template()
    let result = ChatImport.classify(WhatsAppChat.parse(usExport, timeZone: chicago), athlete: "Athlete", coach: "Coach", template: t)
    // A check-in sent from Setecho on the second one's day, and also in the export: the app's counts.
    let sent = CheckInDraft(id: UUID(), weekStart: date(2026, 10, 1, 0, 0), weekEnd: date(2026, 10, 8, 0, 0),
                            answers: [FieldAnswer(fieldId: "current_body_weight", text: "181.6", state: .confirmed, provenance: [])],
                            photoSetId: nil, sentAt: date(2026, 10, 8, 8, 0))
    let series = HistoryTrends.series(template: t, past: result.checkIns, sent: [sent])
    #expect(series.map(\.field.id) == ["current_body_weight", "waist_measurement", "bicep_measurement_flexed", "thigh_measurement_flexed", "fasted_blood_glucose"])
    #expect(series[0].points.map(\.value) == [182.6, 181.6])
    #expect(series[1].points.map(\.value) == [33.0, 32.5])
    #expect(series[2].points.map(\.value) == [15.5])
    #expect(series[4].points.map(\.value) == [92, 90])
    #expect(HistoryTrends.delta(181.6 - 182.6) == "−1" && HistoryTrends.delta(0.04) == "No change")
}

// MARK: The store and the export file

@MainActor
@Test func reimportingSkipsWhatWasAlreadySeen() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-import-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let t = try template()
    let store = Store(root: root)
    store.saveTemplate(t)
    var copied: [String] = []
    let copy: (String, URL) throws -> Void = { file, to in
        copied.append(file)
        try Data("synthetic \(file)".utf8).write(to: to)
    }

    let first = ChatImport.classify(WhatsAppChat.parse(usExport, timeZone: chicago), athlete: "Athlete", coach: "Coach", template: t)
    let added = try store.mergeChat(first, athlete: "Athlete", coach: "Coach", template: t, now: date(2026, 10, 29, 9, 0), copy: copy)
    #expect(added.checkIns == 2 && added.coachMessages == 3)
    #expect(copied.count == 6)
    #expect(FileManager.default.fileExists(atPath: store.mediaDirectory.appendingPathComponent("whatsapp/00000010-PHOTO-2026-10-08-07-36-00.jpg").path))
    #expect(store.chatHistory.seen.count == 15)
    #expect(!store.chatHistory.styleExamples.isEmpty)
    // The first Setecho check-in's "last check-in weight" is the latest imported one.
    #expect(CheckInCoordinator.lastWeight(in: store) == 181.8)

    // The same export again: nothing new. A later export with one more check-in: just that one.
    let again = try store.mergeChat(first, athlete: "Athlete", coach: "Coach", template: t, now: date(2026, 10, 29, 9, 0), copy: copy)
    #expect(again.checkIns == 0 && again.coachMessages == 0 && copied.count == 6)
    let later = usExport + "\n[10/22/26, 7:30:00\u{202F}AM] Athlete: Current body weight: 180.9\nWaist measurement (inches): 32.0\nFasted blood glucose: 89\n[10/22/26, 5:00:00\u{202F}PM] Coach: Good."
    let next = ChatImport.classify(WhatsAppChat.parse(later, timeZone: chicago), athlete: "Athlete", coach: "Coach", template: t)
    let more = try store.mergeChat(next, athlete: "Athlete", coach: "Coach", template: t, now: date(2026, 10, 29, 9, 0), copy: copy)
    #expect(more.checkIns == 1 && more.coachMessages == 1)
    #expect(store.chatHistory.checkIns.count == 3 && store.chatHistory.coachMessages.count == 4)

    // It all survives a relaunch.
    let reopened = Store(root: root)
    #expect(reopened.chatHistory == store.chatHistory)
    #expect(StyleExamples.load(root: root) == store.chatHistory.styleExamples)
    reopened.clearChatHistory()
    #expect(reopened.chatHistory.isEmpty && !FileManager.default.fileExists(atPath: reopened.mediaDirectory.appendingPathComponent("whatsapp").path))
}

@MainActor
@Test func readsAZippedExportAndCopiesOnlyTheKeptFiles() throws {
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("chat-zip-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: work) }
    let folder = work.appendingPathComponent("export")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data(isoExport.utf8).write(to: folder.appendingPathComponent("_chat.txt"))
    try Data("synthetic photo".utf8).write(to: folder.appendingPathComponent("00000020-PHOTO-2026-10-19-07-43-00.jpg"))
    try Data("synthetic video".utf8).write(to: folder.appendingPathComponent("00000021-VIDEO-2026-10-19-07-44-00.mp4"))
    let zipURL = work.appendingPathComponent("WhatsApp Chat.zip")
    try ZipWriter.zip(folder: folder, to: zipURL)

    let export = try ChatExport.read(zipURL, workingCopy: work.appendingPathComponent("copy.zip"))
    #expect(export.text == isoExport)
    let t = try template()
    let store = Store(root: work.appendingPathComponent("store"))
    let result = ChatImport.classify(WhatsAppChat.parse(export.text, timeZone: chicago), athlete: "Athlete", coach: "Coach", template: t)
    try store.mergeChat(result, athlete: "Athlete", coach: "Coach", template: t) { try export.copy($0, to: $1) }
    let photo = store.mediaDirectory.appendingPathComponent("whatsapp/00000020-PHOTO-2026-10-19-07-43-00.jpg")
    #expect(try Data(contentsOf: photo) == Data("synthetic photo".utf8))
    #expect(!fm.fileExists(atPath: store.mediaDirectory.appendingPathComponent("whatsapp/00000021-VIDEO-2026-10-19-07-44-00.mp4").path))
    #expect(store.chatHistory.coachMessages.map(\.text) == ["Down again, good."])
}

@Test func zipReaderInflatesDeflatedEntries() throws {
    let chat = Data(String(repeating: usExport + "\n", count: 4).utf8)
    let zip = try ZipReader(data: deflatedZip(name: "_chat.txt", contents: chat))
    let entry = try #require(zip.entry(named: "_chat.txt"))
    #expect(entry.method == 8 && entry.compressedSize < chat.count)
    #expect(try zip.extract(entry) == chat)
    #expect(throws: ZipReader.ReadError.self) { try ZipReader(data: Data("not a zip at all, just text".utf8)) }
}

/// A one-entry zip with the entry deflated, the way WhatsApp writes most of its export.
private func deflatedZip(name: String, contents: Data) -> Data {
    var compressed = Data(count: contents.count + 1024)
    let size = compressed.withUnsafeMutableBytes { dst in
        contents.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, dst.count,
                                      src.bindMemory(to: UInt8.self).baseAddress!, contents.count, nil, COMPRESSION_ZLIB)
        }
    }
    compressed = compressed.prefix(size)
    func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
    func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    let nameBytes = Data(name.utf8)
    let crc = ZipWriter.crc32(contents)
    // Shared by the local header and the central directory: version, flags, method, time, date, crc, sizes, name length.
    var fields = Data()
    for part in [le16(8), le16(0), le16(0x21), le32(crc), le32(UInt32(compressed.count)), le32(UInt32(contents.count)), le16(nameBytes.count)] {
        fields.append(part)
    }
    var out = Data()
    for part in [le32(0x0403_4b50), le16(20), le16(0x0800), fields, le16(0), nameBytes, compressed] { out.append(part) }
    var central = Data()
    for part in [le32(0x0201_4b50), le16(20), le16(20), le16(0x0800), fields, le16(0), le16(0), le16(0), le16(0), le32(0), le32(0), nameBytes] {
        central.append(part)
    }
    let offset = UInt32(out.count)
    out.append(central)
    for part in [le32(0x0605_4b50), le16(0), le16(0), le16(1), le16(1), le32(UInt32(central.count)), le32(offset), le16(0)] { out.append(part) }
    return out
}
