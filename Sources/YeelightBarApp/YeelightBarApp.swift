import SwiftUI
import AppKit

@main
struct YeelightBarApp: App {
    @StateObject private var lamp = LampController()
    @StateObject private var updater = UpdaterViewModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Full resizable app window (Dock icon, proper configuration surface).
        Window("YeelightBar", id: "main") {
            FullView(lamp: lamp, updater: updater)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Проверить обновления…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        // Mini quick-controls in the status bar — custom light-bar glyph, not the stock SF Symbol.
        MenuBarExtra {
            MenuPanelView(lamp: lamp)
        } label: {
            Image(nsImage: Self.menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }

    /// Monochrome menu-bar glyph (light bar + rays). A template image, so macOS tints it for
    /// light/dark menu bars automatically.
    static var menuBarImage: NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 6, width: 14, height: 3.4), xRadius: 1.7, yRadius: 1.7).fill()
            for (x0, x1, top) in [(5.5, 5.0, 14.5), (9.0, 9.0, 15.0), (12.5, 13.0, 14.5)] as [(CGFloat, CGFloat, CGFloat)] {
                let ray = NSBezierPath(); ray.lineWidth = 1.4; ray.lineCapStyle = .round
                ray.move(to: NSPoint(x: x0, y: 11)); ray.line(to: NSPoint(x: x1, y: top)); ray.stroke()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force the running Dock icon to the bundled .icns (busts LaunchServices' iconless cache).
        if let u = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: u) { NSApplication.shared.applicationIconImage = img }
        ThemeManager.shared.applyAppearance()   // restore the saved light/dark override
    }
}
