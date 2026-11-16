import Charts
import SwiftUI
import MeetingCore

// Select the property wrapper explicitly; newer SDKs also export a State macro.
private typealias DashboardState<Value> = SwiftUI.State<Value>

struct APIUsageDashboard: View {
    @Bindable var model: AppModel
    @DashboardState private var period = Period.week
    @DashboardState private var metric = Metric.total
    @DashboardState private var selectedDate: Date?
    @DashboardState private var report: APIUsageReport?

    // Selection and metric changes only redraw the cached report. Snapshot values
    // are copy-on-write; aggregation runs away from the main actor.
    private struct ReportRequest: Equatable, Sendable {
        let recordings: [Recording]
        let documents: [UUID: TranscriptDocument]
        let days: Int?
        let day: Date
    }

    private enum Period: String, CaseIterable {
        case week = "近 7 天", month = "近 30 天", all = "全部"
        var days: Int? { self == .week ? 7 : self == .month ? 30 : nil }
    }

    private enum Metric: String, CaseIterable {
        case total = "总 Token", input = "输入", output = "输出"
        func value(_ usage: APIUsageTotals) -> Int? {
            switch self {
            case .total: usage.totalTokens
            case .input: usage.inputTokens
            case .output: usage.outputTokens
            }
        }
    }

    private struct PlotPoint: Identifiable {
        var id: Date { date }
        let date: Date
        let value: Int
        let segment: Int
    }

    private let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let request = ReportRequest(recordings: model.recordings, documents: model.transcription.documents,
                                        days: period.days, day: Calendar.current.startOfDay(for: context.date))
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        heading
                        Spacer()
                        periodPicker.frame(width: 240)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        heading
                        periodPicker
                    }
                }
                if let report {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], spacing: 12) {
                        statistic("已报告 Token", value: report.total.totalTokens)
                        statistic("输入 Token", value: report.total.inputTokens)
                        statistic("输出 Token", value: report.total.outputTokens)
                    }
                    HStack {
                        Text("每日用量").font(.callout.weight(.medium))
                        Spacer()
                        Picker("用量指标", selection: $metric) {
                            ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 210)
                            .accessibilityLabel("折线图用量指标")
                    }
                    usageChart(report)
                    if !report.series.isEmpty {
                        seriesLegend(report)
                    }
                    if report.total.incompleteResultCount > 0 {
                        Label("\(report.total.incompleteResultCount) 项结果未返回完整用量；图表与合计仅包含已报告的 Token。", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    ProgressView("正在统计本地用量…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                }
                Text("按 model name 与 Key ID 合并，每条折线代表一个组合。Key ID 是本地生成的密钥指纹；历史未记录的 Key 单独归组。新记录按请求完成日期，旧记录按摘要或会议日期归集；缺失用量不画为 0。仅统计当前保留的结果，实际费用以服务商账单为准。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .task(id: request) {
                let calculation = Task.detached(priority: .userInitiated) {
                    APIUsageReport(recordings: request.recordings, documents: request.documents,
                                   days: request.days, now: request.day)
                }
                let snapshot = await calculation.value
                // A newer range or document snapshot may already be in flight.
                guard !Task.isCancelled else { return }
                report = snapshot
            }
        }
        .onChange(of: period) { selectedDate = nil }
        .onChange(of: metric) { selectedDate = nil }
    }

    private var heading: some View {
        Label("API Token 用量", systemImage: "chart.xyaxis.line")
            .font(.headline).fixedSize()
    }

    private var periodPicker: some View {
        Picker("统计范围", selection: $period) {
            ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Token 用量统计范围")
    }

    private func usageChart(_ report: APIUsageReport) -> some View {
        Chart {
            ForEach(report.series) { series in
                ForEach(plotPoints(series)) { point in
                    LineMark(x: .value("日期", point.date), y: .value("Token", point.value),
                             series: .value("连续区间", "\(series.label)#\(point.segment)"))
                        .foregroundStyle(by: .value("Model / Key ID", series.label))
                        .interpolationMethod(.linear)
                    PointMark(x: .value("日期", point.date), y: .value("Token", point.value))
                        .foregroundStyle(by: .value("Model / Key ID", series.label))
                        .symbol(by: .value("Model / Key ID", series.label))
                        .symbolSize(24)
                        .accessibilityLabel(series.label)
                        .accessibilityValue("\(point.date.formatted(date: .abbreviated, time: .omitted))，\(point.value) Token")
                }
            }
            if let selectedDate {
                RuleMark(x: .value("选中日期", Calendar.current.startOfDay(for: selectedDate)))
                    .foregroundStyle(.secondary.opacity(0.4))
            }
        }
        .chartForegroundStyleScale(domain: report.series.map(\.label),
                                   range: report.series.indices.map { colors[$0 % colors.count] })
        .chartLegend(.hidden)
        .chartXScale(domain: report.dateRange)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.month().day())
            }
        }
        .chartYAxisLabel("Token")
        .chartXSelection(value: $selectedDate)
        .frame(height: 220)
        .overlay {
            if metric.value(report.total) == nil {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line").font(.title2)
                    Text(report.series.isEmpty ? "这段时间暂无云端用量记录" : "服务未返回此指标的用量")
                        .font(.callout)
                }
                .foregroundStyle(.secondary).padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
            }
        }
    }

    private func plotPoints(_ series: APIUsageReport.Series) -> [PlotPoint] {
        guard metric.value(series.total) != nil else { return [] }
        var segment = 0
        return series.days.compactMap { day in
            // A day with no calls is zero; a result with missing usage breaks the line.
            guard let value = day.usage.resultCount == 0 ? 0 : metric.value(day.usage) else {
                segment += 1
                return nil
            }
            return PlotPoint(date: day.date, value: value, segment: segment)
        }
    }

    private func seriesLegend(_ report: APIUsageReport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Model / Key ID").font(.caption.weight(.medium))
                Spacer()
                Text(selectedDate?.formatted(date: .abbreviated, time: .omitted) ?? "所选范围合计")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(report.series.enumerated()), id: \.element.id) { index, series in
                HStack(spacing: 10) {
                    Circle().fill(colors[index % colors.count]).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(series.identity.modelName ?? "未知模型").font(.callout.weight(.medium))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text(series.identity.keyID ?? "历史 Key 未记录").font(.caption.monospaced())
                            .foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                    Text("\(tokens(selectedValue(series))) Token")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func selectedValue(_ series: APIUsageReport.Series) -> Int? {
        guard let selectedDate else { return metric.value(series.total) }
        guard let day = series.days.first(where: { Calendar.current.isDate($0.date, inSameDayAs: selectedDate) }) else { return nil }
        return day.usage.resultCount == 0 ? 0 : metric.value(day.usage)
    }

    private func tokens(_ value: Int?) -> String { value?.formatted() ?? "—" }

    private func statistic(_ title: String, value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(tokens(value)).font(.system(size: 25, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
