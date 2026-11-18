import Foundation

/// A snapshot of usage retained in meeting documents, not a billing ledger.
public struct APIUsageTotals: Sendable, Equatable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let resultCount: Int
    public let incompleteResultCount: Int
    public var totalTokens: Int? {
        guard inputTokens != nil || outputTokens != nil else { return nil }
        return (inputTokens ?? 0) + (outputTokens ?? 0)
    }

    init(_ values: [TranscriptionUsage?]) {
        let inputs = values.compactMap { $0?.inputTokens }.filter { $0 >= 0 }
        let outputs = values.compactMap { $0?.outputTokens }.filter { $0 >= 0 }
        inputTokens = inputs.isEmpty ? nil : inputs.reduce(0, +)
        outputTokens = outputs.isEmpty ? nil : outputs.reduce(0, +)
        resultCount = values.count
        incompleteResultCount = values.filter {
            ($0?.inputTokens ?? -1) < 0 || ($0?.outputTokens ?? -1) < 0
        }.count
    }
}

public struct APIUsageReport: Sendable {
    public struct Meeting: Identifiable, Sendable {
        public let id: UUID
        public let title: String
        public let date: Date
        public let transcription: APIUsageTotals
        public let summary: APIUsageTotals
        public let total: APIUsageTotals
    }

    public struct Day: Identifiable, Sendable {
        public var id: Date { date }
        public let date: Date
        public let usage: APIUsageTotals
    }

    public struct Series: Identifiable, Sendable {
        public var id: APIUsageIdentity { identity }
        public let identity: APIUsageIdentity
        public let days: [Day]
        public let total: APIUsageTotals
        public var label: String {
            "\(identity.modelName ?? "未知模型") · \(identity.keyID ?? "历史 Key 未记录")"
        }
    }

    private struct Sample {
        let recording: Recording
        let date: Date
        let usage: TranscriptionUsage?
        let identity: APIUsageIdentity
        let isSummary: Bool
    }

    public let meetings: [Meeting]
    public let series: [Series]
    public let dateRange: ClosedRange<Date>
    public let transcription: APIUsageTotals
    public let summary: APIUsageTotals
    public let total: APIUsageTotals

    /// New results use their completion date. Legacy data falls back to summary or meeting dates.
    public init(recordings: [Recording], documents: [UUID: TranscriptDocument], days: Int?,
                now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let start = days.flatMap { calendar.date(byAdding: .day, value: 1 - max(1, $0), to: today) }
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        var samples: [Sample] = []
        for recording in recordings {
            guard let document = documents[recording.id], document.recordingID == recording.id else { continue }
            if let cloud = document.cloud {
                let jobs = Array(cloud.jobs.values) + (cloud.history ?? []).flatMap { Array(($0.jobs ?? [:]).values) }
                for job in jobs where job.completed && !job.skippedSilence {
                    samples.append(Sample(recording: recording, date: job.usage?.recordedAt ?? recording.startedAt,
                        usage: job.usage, identity: APIUsageIdentity(modelName: job.usage?.modelName ?? cloud.configuration.model,
                                                                   keyID: job.usage?.keyID), isSummary: false))
                }
            }
            if let cloud = document.cloud {
                let sessions = (cloud.sessions ?? []) + (cloud.history ?? []).flatMap(\.sessions)
                for session in sessions where session.status == "completed" {
                    samples.append(Sample(recording: recording, date: session.usage?.recordedAt ?? recording.startedAt,
                        usage: session.usage, identity: APIUsageIdentity(modelName: session.usage?.modelName ?? session.model, keyID: session.usage?.keyID), isSummary: false))
                }
            }
            // Failed retries can retain a previous successful summary and its usage.
            if let summary = document.summary,
               summary.generatedAt != nil || summary.status == "completed" || summary.usage != nil {
                samples.append(Sample(recording: recording,
                    date: summary.usage?.recordedAt ?? summary.generatedAt ?? recording.startedAt,
                    usage: summary.usage, identity: APIUsageIdentity(modelName: summary.usage?.modelName ?? summary.model,
                                                                   keyID: summary.usage?.keyID), isSummary: true))
            }
        }
        samples = samples.filter { sample in
            sample.date < end && (start.map { sample.date >= $0 } ?? true)
        }
        let firstDay = start ?? samples.map { calendar.startOfDay(for: $0.date) }.min() ?? today
        var dates: [Date] = []
        var date = firstDay
        while date <= today {
            dates.append(date)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = next
        }
        // Give a single-day series room for a visible point and a selectable date.
        dateRange = (firstDay == today ? today.addingTimeInterval(-43200) : firstDay)...today.addingTimeInterval(43200)
        series = Dictionary(grouping: samples, by: \.identity).map { identity, values in
            let daily = Dictionary(grouping: values) { calendar.startOfDay(for: $0.date) }
            return Series(identity: identity,
                          days: dates.map { Day(date: $0, usage: APIUsageTotals(daily[$0, default: []].map(\.usage))) },
                          total: APIUsageTotals(values.map(\.usage)))
        }.sorted { $0.label < $1.label }
        meetings = Dictionary(grouping: samples, by: { $0.recording.id }).map { id, values in
            Meeting(id: id, title: values[0].recording.title, date: values.map(\.date).max()!,
                    transcription: APIUsageTotals(values.filter { !$0.isSummary }.map(\.usage)),
                    summary: APIUsageTotals(values.filter(\.isSummary).map(\.usage)), total: APIUsageTotals(values.map(\.usage)))
        }.sorted { $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date }
        transcription = APIUsageTotals(samples.filter { !$0.isSummary }.map(\.usage))
        summary = APIUsageTotals(samples.filter(\.isSummary).map(\.usage))
        total = APIUsageTotals(samples.map(\.usage))
    }
}
