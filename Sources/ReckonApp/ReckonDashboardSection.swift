import SwiftUI

/// The desktop sidebar and menu-bar tabs use the same destinations and full section names.
enum ReckonDashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case accounts = "Accounts"
    case activity = "Activity"
    case forecast = "Dead reckoning"
    case spending = "The bleed"
    case standingOrders = "Standing orders"

    var id: Self { self }
    var shortLabel: String {
        switch self {
        case .forecast: "Forecast"
        case .spending: "Spending"
        case .standingOrders: "Bills"
        default: rawValue
        }
    }
    var systemImage: String {
        switch self {
        case .overview: "chart.bar.xaxis"
        case .accounts: "building.columns"
        case .activity: "list.bullet.rectangle"
        case .forecast: "chart.xyaxis.line"
        case .spending: "chart.pie"
        case .standingOrders: "calendar.badge.clock"
        }
    }
}
