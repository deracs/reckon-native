import Charts
import ReckonCore
import SwiftUI

/// Displays the existing NZD forecast with its actual payday date and no new calculation assumptions.
struct BankDesktopForecastChart: View {
    let forecast: BankForecast
    @State private var selectedDate: Date?

    private var points: [BankChartPoint] {
        forecast.points.compactMap { point in
            BankCalendar.date(point.date).map { BankChartPoint(id: point.date, date: $0, balance: point.projectedBalance.value) }
        }
    }
    private var selectedPoint: BankChartPoint? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }
    private var range: ClosedRange<Double> {
        let values = points.map { NSDecimalNumber(decimal: $0.balance).doubleValue }
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let padding = max((high - low) * 0.2, 100)
        return (low - padding)...(high + padding)
    }
    private var color: Color { forecast.endingBalance.value < 0 ? .orange : ReckonDesktopAppearance.income }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Dead reckoning").font(.system(size: 18, weight: .semibold))
                Text("30-day estimate").font(.system(size: 12)).foregroundStyle(.secondary)
                ReckonInfoHelp(subject: "Dead reckoning", explanation: "A 30-day estimate for NZD checking and savings, using detected regular income and bills. Everyday spending and unexpected payments are excluded. Hover or drag to inspect a day.")
            }
            HStack {
                Text(selectedPoint.map { "\(BankCalendar.label($0.id)) · \(BankFormatting.money($0.balance))" } ?? " ")
                Spacer()
                Text("\(BankFormatting.money(forecast.endingBalance.value)) est.")
                    .foregroundStyle(color).fontWeight(.medium)
            }
            .font(.system(size: 11)).monospacedDigit().padding(.top, 8)
            Chart {
                ForEach(points) { point in
                    AreaMark(x: .value("Date", point.date), yStart: .value("Base", range.lowerBound),
                             yEnd: .value("Balance", NSDecimalNumber(decimal: point.balance).doubleValue))
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.16), color.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", point.date), y: .value("Balance", NSDecimalNumber(decimal: point.balance).doubleValue))
                        .interpolationMethod(.stepEnd).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 2))
                }
                if let payday = forecast.estimatedPayday, let date = BankCalendar.date(payday.date) {
                    RuleMark(x: .value("Estimated payday", date)).foregroundStyle(.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .top) {
                            Text("+\(BankFormatting.money(payday.amount.value, compact: true))")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(color)
                                .padding(4).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                        }
                }
                if let point = selectedPoint {
                    PointMark(x: .value("Date", point.date), y: .value("Balance", NSDecimalNumber(decimal: point.balance).doubleValue))
                        .foregroundStyle(color)
                }
            }
            .chartYScale(domain: range)
            .chartXScale(range: .plotDimension(padding: 20))
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.04))
                    AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active(let location) = phase { selectDate(at: location, proxy: proxy, geometry: geometry) }
                            else { selectedDate = nil }
                        }
                        .gesture(DragGesture(minimumDistance: 0).onChanged { selectDate(at: $0.location, proxy: proxy, geometry: geometry) })
                }
            }
            .frame(height: 208)
            .environment(\.calendar, BankCalendar.calendar).environment(\.timeZone, BankCalendar.calendar.timeZone)
            Text("NZD · excludes everyday spending").font(.system(size: 11)).foregroundStyle(.secondary)
            if let risk = forecast.risks.first {
                BankDesktopSectionError(message: "Could fall below zero on \(BankCalendar.label(risk.date)): \(BankFormatting.money(risk.projectedBalance.value)).")
            }
        }
    }

    private func selectDate(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let frame = proxy.plotFrame else { return }
        selectedDate = proxy.value(atX: location.x - geometry[frame].origin.x, as: Date.self)
    }
}

/// The full forecast page exposes the source estimate and its dated events without synthesizing bills.
struct BankDesktopForecastPage: View {
    let forecast: BankSection<BankForecast>
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let value = forecast.value {
                Text("\(BankFormatting.money(value.endingBalance.value)) in 30 days")
                    .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                BankDesktopForecastChart(forecast: value)
                Divider()
                Text("Estimated income and bills").font(.headline)
                ForEach(Array(value.events.sorted { $0.date < $1.date }.enumerated()), id: \.offset) { _, event in
                    HStack {
                        Text(BankCalendar.label(event.date)).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
                        Text(event.description)
                        Spacer()
                        Text(BankFormatting.money(event.amount.value)).monospacedDigit()
                            .foregroundStyle(event.amount.value > 0 ? ReckonDesktopAppearance.income : Color.primary)
                    }.font(.callout)
                }
                if value.events.isEmpty { Text("No regular income or bills detected.").foregroundStyle(.secondary) }
            } else { BankDesktopSectionError(message: forecast.errorMessage ?? "Forecast unavailable.") }
        }
    }
}
