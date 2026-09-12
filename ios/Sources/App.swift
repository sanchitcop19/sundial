import SwiftUI

@main
struct SundialMobileApp: App {
    @StateObject private var library = Library()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(library)
        }
    }
}
