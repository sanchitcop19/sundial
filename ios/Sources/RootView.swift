import SwiftUI
import SundialCore

struct RootView: View {
    @EnvironmentObject var library: Library
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if library.folder == nil { ConnectView() } else { MainTabs() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            library.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
                library.refreshProgress()
            }
        }
    }
}

struct MainTabs: View {
    @EnvironmentObject var library: Library
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            TodayView()
                .tabItem { Label("Today", systemImage: "chart.bar.fill") }
                .tag(0)
            MobileReviewView()
                .tabItem { Label("Review", systemImage: "questionmark.circle") }
                .badge(library.reviewItems.count)
                .tag(1)
            DurationEntryView()
                .tabItem { Label("Add Time", systemImage: "clock.badge.plus") }
                .tag(2)
        }
        .onOpenURL { url in
            if url.scheme == "sundial", url.host == "progress" { selection = 0 }
        }
    }
}
