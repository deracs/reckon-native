import Charts
import ReckonCore
import SwiftUI

struct BankChartPoint: Identifiable {
    let id: String
    let date: Date
    let balance: Decimal
}

struct BankLineChart: View {
    let points: [BankChartPoint]
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDate: Date?
    @State private var revealed = false

    private var tint: Color {
        guard let first = points.first, let last = points.last else { return .secondary }
        return last.balance >= first.balance ? .green : .orange
    }

    private var selectedPoint: BankChartPoint? {
        guard let selectedDate else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !compact {
                Text(selectedPoint.map { "\(BankCalendar.label($0.id)) · \(BankFormatting.money($0.balance))" } ?? " ")
                    .font(.caption).monospacedDigit().frame(height: 16)
                    .accessibilityHidden(selectedPoint == nil)
            }
            Chart(points) { point in
                LineMark(x: .value("Date", point.date), y: .value("Balance", NSDecimalNumber(decimal: point.balance).doubleValue))
                    .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: compact ? 1.5 : 2))
                    .interpolationMethod(compact ? .linear : .stepEnd)
                if !compact, let selectedPoint, selectedPoint.id == point.id {
                    PointMark(x: .value("Date", point.date), y: .value("Balance", NSDecimalNumber(decimal: point.balance).doubleValue))
                        .foregroundStyle(tint)
                }
            }
            .chartOverlay { proxy in
                if !compact {
                    GeometryReader { geometry in
                        Color.clear.contentShape(Rectangle())
                            .onContinuousHover { phase in
                                if case .active(let location) = phase { selectChartDate(at: location, proxy: proxy, geometry: geometry) }
                            }
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                selectChartDate(at: value.location, proxy: proxy, geometry: geometry)
                            })
                    }
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(compact ? .hidden : .automatic)
            .chartYScale(domain: .automatic(includesZero: false))
            .opacity(revealed ? 1 : 0)
            .animation(.easeOut(duration: reduceMotion ? 0 : 0.35), value: revealed)
            .onAppear { revealed = true }
            if !compact, let first = points.first, let last = points.last {
                HStack {
                    Text(BankCalendar.label(first.id))
                    Spacer()
                    Text(BankCalendar.label(last.id))
                }.font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func selectChartDate(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard let frame = proxy.plotFrame else { return }
        let x = location.x - geometry[frame].origin.x
        selectedDate = proxy.value(atX: x, as: Date.self)
    }
}

struct AccountBalanceHistoryView: View {
    let samples: [BankBalanceSample]

    var body: some View {
        if samples.count >= 2 {
            BankLineChart(points: samples.compactMap { sample in
                BankCalendar.date(sample.day).map { BankChartPoint(id: sample.day, date: $0, balance: sample.balance) }
            }, compact: true)
            .frame(width: 80, height: 18)
            .accessibilityLabel("Balance trend from \(samples.first?.day ?? "") to \(samples.last?.day ?? "")")
        } else {
            Text("History starts today").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}
