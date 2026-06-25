import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar agent, no Dock icon
    }
}

@main
struct YeelightBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var lamp = LampController()

    var body: some Scene {
        MenuBarExtra("Yeelight", systemImage: "lightbulb") {
            MenuPanelView(lamp: lamp)
        }
        .menuBarExtraStyle(.window)
    }
}
