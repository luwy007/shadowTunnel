import SwiftUI

@main
struct shadowTunnelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            ContentView(viewModel: appDelegate.viewModel)
                .frame(minWidth: 420, minHeight: 320)
        }
    }
}
