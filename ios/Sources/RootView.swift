import SwiftUI
import SundialCore

struct RootView: View {
    @EnvironmentObject var library: Library

    var body: some View {
        Group {
            if library.folder == nil { ConnectView() } else { MainTabs() }
        }
        .task { library.refresh() }
    }
}

struct MainTabs: View {
    @EnvironmentObject var library: Library

    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("Today", systemImage: "chart.bar.fill") }
            MobileReviewView()
                .tabItem { Label("Review", systemImage: "questionmark.circle") }
                .badge(library.reviewItems.count)
            SessionView()
                .tabItem { Label("Session", systemImage: "record.circle") }
        }
    }
}
