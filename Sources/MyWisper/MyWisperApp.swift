import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLineTools.run(CommandLine.arguments) { return }
        MyWisperApp.main()
    }
}

struct MyWisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var prefs = Preferences.shared
    @StateObject private var history = HistoryStore.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(prefs)
                .environmentObject(history)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(prefs)
                .environmentObject(history)
        }

        Window("历史记录", id: "history") {
            HistoryWindow().environmentObject(history)
        }
        .defaultSize(width: 520, height: 600)
        .defaultLaunchBehavior(.suppressed)

        Window("欢迎", id: "welcome") {
            WelcomeView()
                .environmentObject(model)
                .environmentObject(prefs)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.launch() }
    }
}
