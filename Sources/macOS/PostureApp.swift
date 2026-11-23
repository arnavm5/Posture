import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = PostureMonitor()
    private var notch: NotchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        notch = NotchController(monitor: monitor)
    }
}

@main
struct PostureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(delegate.monitor)
        } label: {
            MenuBarIcon(monitor: delegate.monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var monitor: PostureMonitor
    var body: some View { Image(systemName: monitor.state.symbol) }
}
