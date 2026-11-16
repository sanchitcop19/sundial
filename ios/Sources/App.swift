import SwiftUI
import BackgroundTasks

@main
struct SundialMobileApp: App {
    @StateObject private var library = Library()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(library)
                .environmentObject(library.liveActivity)
                .tint(MobileTheme.accent)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { scheduleRefresh() }
        }
        .backgroundTask(.appRefresh("dev.sanchit.sundial.mobile.refresh")) {
            await library.refreshInBackground()
            await MainActor.run {
                scheduleRefresh()
            }
        }
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: "dev.sanchit.sundial.mobile.refresh")
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
