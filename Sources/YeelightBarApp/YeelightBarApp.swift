import SwiftUI
import AppKit

@main
struct YeelightBarApp: App {
    @StateObject private var lamp = LampController()

    var body: some Scene {
        // Full resizable app window (Dock icon, proper configuration surface).
        Window("YeelightBar", id: "main") {
            FullView(lamp: lamp)
        }
        .windowResizability(.contentSize)

        // Mini quick-controls in the status bar.
        MenuBarExtra("Yeelight", systemImage: "lightbulb") {
            MenuPanelView(lamp: lamp)
        }
        .menuBarExtraStyle(.window)
    }
}
