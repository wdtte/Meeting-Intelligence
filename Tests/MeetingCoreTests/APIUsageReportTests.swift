import Foundation
import Testing
@testable import MeetingCore

@Test func apiUsageSeparatesServicesAndKeepsMissingUsageDistinctFromZero() {
    let now = Date()
    var recording = Recording.systemAudio(title: "用量测试")
    recording.startedAt = now
    var document = TranscriptDocument(recordingID: recording.id, locale: "zh-CN")
    var cloud = CloudTranscriptionProgress(configuration: CloudTranscriptionConfiguration())
    var known = CloudChunkJob()
    known.completed = true
    known.usage = TranscriptionUsage(inputTokens: 100, outputTokens: 20)
    var unknown = CloudChunkJob()
    unknown.completed = true
    var partial = CloudChunkJob()
    partial.completed = true
    partial.usage = TranscriptionUsage(inputTokens: 30)
    var skipped = known
    skipped.skippedSilence = true
    var pending = known
    pending.completed = false
    cloud.jobs = ["known": known, "unknown": unknown, "partial": partial, "skipped": skipped, "pending": pending]
    document.cloud = cloud
    var summary = TranscriptSummary(inputFingerprint: "fixture")
    summary.status = "completed"
    summary.usage = TranscriptionUsage(inputTokens: 50, outputTokens: 0)
    document.summary = summary

    let report = APIUsageReport(recordings: [recording], documents: [recording.id: document], days: 7, now: now)
    #expect(report.transcription.totalTokens == 150)
    #expect(report.summary.totalTokens == 50)
    #expect(report.summary.outputTokens == 0)
    #expect(report.total.inputTokens == 180)
    #expect(report.total.outputTokens == 20)
    #expect(report.total.resultCount == 4)
    #expect(report.total.incompleteResultCount == 2)
    #expect(report.meetings.count == 1)

    document.cloud?.jobs = ["unknown": unknown]
    document.summary = nil
    let missing = APIUsageReport(recordings: [recording], documents: [recording.id: document], days: nil, now: now)
    #expect(missing.total.totalTokens == nil)
    #expect(missing.meetings.count == 1)
    #expect(missing.total.incompleteResultCount == 1)
}

@Test func apiUsageFiltersByLocalMeetingDayAndSortsRecentFirst() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
    let now = today.addingTimeInterval(12 * 3600)
    var recordings: [Recording] = []
    var documents: [UUID: TranscriptDocument] = [:]
    for dayOffset in [-7, -6, 0, 1] {
        var recording = Recording.systemAudio(title: "\(dayOffset)")
        recording.startedAt = try #require(calendar.date(byAdding: .day, value: dayOffset, to: today))
        var document = TranscriptDocument(recordingID: recording.id, locale: "zh-CN")
        document.summary = TranscriptSummary(inputFingerprint: "fixture")
        document.summary?.status = "completed"
        document.summary?.usage = TranscriptionUsage(inputTokens: 10, outputTokens: 5)
        recordings.append(recording)
        documents[recording.id] = document
    }
    let week = APIUsageReport(recordings: recordings, documents: documents, days: 7, now: now, calendar: calendar)
    #expect(week.meetings.map(\.title) == ["0", "-6"])
    #expect(week.total.totalTokens == 30)
    let all = APIUsageReport(recordings: recordings, documents: documents, days: nil, now: now, calendar: calendar)
    #expect(all.meetings.count == 3)
}

@Test func apiUsageUsesCurrentSnapshotsAndRetainsUsageDuringFailedSummaryRetry() {
    let recording = Recording.systemAudio(title: "已保留的摘要")
    let local = Recording.systemAudio(title: "仅本地转写")
    var document = TranscriptDocument(recordingID: recording.id, locale: "zh-CN")
    document.summary = TranscriptSummary(inputFingerprint: "fixture")
    document.summary?.generatedAt = Date()
    document.summary?.status = "failed"
    document.summary?.usage = TranscriptionUsage(inputTokens: 20, outputTokens: 5)
    let documents = [recording.id: document, local.id: TranscriptDocument(recordingID: local.id, locale: "zh-CN")]
    let report = APIUsageReport(recordings: [local, recording], documents: documents, days: nil)
    #expect(report.meetings.count == 1)
    #expect(report.total.totalTokens == 25)
    let deleted = APIUsageReport(recordings: [local], documents: documents, days: nil)
    #expect(deleted.meetings.isEmpty)
    #expect(deleted.total.totalTokens == nil)
}

@Test func apiUsageIdentityNormalizesModelsAndFingerprintsKeysWithoutPersistingSecrets() throws {
    let identity = APIUsageIdentity(modelName: " gpt-4o-mini\n", keyID: " key-fixture ")
    #expect(identity == APIUsageIdentity(modelName: "gpt-4o-mini", keyID: "key-fixture"))
    #expect(identity != APIUsageIdentity(modelName: "GPT-4o-mini", keyID: "key-fixture"))
    #expect(APIUsageIdentity(modelName: " ", keyID: "\n").modelName == nil)
    #expect(APIUsageIdentity.keyID(for: " fixture-key ") == APIUsageIdentity.keyID(for: "fixture-key"))
    #expect(APIUsageIdentity.keyID(for: "fixture-key") != APIUsageIdentity.keyID(for: "different-key"))
    #expect(APIUsageIdentity.keyID(for: " ") == nil)
    let legacy = try JSONDecoder().decode(TranscriptionUsage.self, from: Data(#"{"inputTokens":3,"outputTokens":1}"#.utf8))
    #expect(legacy.modelName == nil && legacy.keyID == nil && legacy.recordedAt == nil)
    let usage = legacy.attributed(modelName: " gpt-4o-mini ", apiKey: "fixture-secret-key")
    let encoded = try JSONEncoder().encode(usage)
    #expect(!String(decoding: encoded, as: UTF8.self).contains("fixture-secret-key"))
    #expect(try JSONDecoder().decode(TranscriptionUsage.self, from: encoded) == usage)
}

@Test func apiUsageGroupsByModelAndKeyAcrossMeetingsAndUsesCompletionDates() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let today = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
    let yesterday = try #require(calendar.date(byAdding: .day, value: -1, to: today))
    let oldDate = try #require(calendar.date(byAdding: .day, value: -60, to: today))
    var recordings: [Recording] = []
    var documents: [UUID: TranscriptDocument] = [:]
    let fixtures: [(String, String, Date, Int)] = [
        (" model-a ", "first-key", today, 10),
        ("model-a", "first-key", today, 20),
        ("model-a", "first-key", yesterday, 30),
        ("model-a", "second-key", today, 40),
        ("model-b", "first-key", today, 50)
    ]
    for (modelName, key, date, count) in fixtures {
        var recording = Recording.systemAudio(title: modelName)
        recording.startedAt = oldDate
        var document = TranscriptDocument(recordingID: recording.id, locale: "zh-CN")
        document.summary = TranscriptSummary(inputFingerprint: "fixture")
        document.summary?.status = "completed"
        document.summary?.usage = TranscriptionUsage(inputTokens: count, outputTokens: 2)
            .attributed(modelName: modelName, apiKey: key, at: date)
        recordings.append(recording)
        documents[recording.id] = document
    }
    let report = APIUsageReport(recordings: recordings, documents: documents, days: 7, now: today, calendar: calendar)
    #expect(report.series.count == 3)
    #expect(report.total.totalTokens == 160)
    let merged = try #require(report.series.first { $0.identity == APIUsageIdentity(modelName: "model-a", keyID: APIUsageIdentity.keyID(for: "first-key")) })
    #expect(merged.total.totalTokens == 66)
    #expect(merged.days.count == 7)
    #expect(merged.days.last?.usage.totalTokens == 34)
    #expect(merged.days.dropLast().last?.usage.totalTokens == 32)
    #expect(merged.days.first?.usage.resultCount == 0)
    #expect(merged.days.first?.usage.totalTokens == nil)
}

@Test func apiUsageKeepsLegacyKeysSeparateAndPreservesUnknownDailyUsage() throws {
    let now = Date()
    let recording = Recording.systemAudio(title: "历史与新结果")
    var document = TranscriptDocument(recordingID: recording.id, locale: "zh-CN")
    var cloud = CloudTranscriptionProgress(configuration: .init())
    var legacy = CloudChunkJob()
    legacy.completed = true
    legacy.usage = TranscriptionUsage(inputTokens: 12, outputTokens: 2)
    var known = legacy
    known.usage = known.usage?.attributed(modelName: cloud.configuration.model, apiKey: "current-key", at: now)
    var unknown = CloudChunkJob()
    unknown.completed = true
    cloud.jobs = ["legacy": legacy, "known": known, "unknown": unknown]
    document.cloud = cloud
    let report = APIUsageReport(recordings: [recording], documents: [recording.id: document], days: 7, now: now)
    #expect(report.series.count == 2)
    let historical = try #require(report.series.first { $0.identity.keyID == nil })
    #expect(historical.total.totalTokens == 14)
    #expect(historical.total.incompleteResultCount == 1)
    #expect(historical.days.last?.usage.incompleteResultCount == 1)
    #expect(report.total.totalTokens == 28)
}
