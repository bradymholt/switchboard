import SwiftUI
import UserNotifications

@main
struct SwitchboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ServiceStore.shared

    var body: some Scene {
        Settings { EmptyView() }
            .defaultLaunchBehavior(.suppressed)
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Edit Services…", action: ConfigFile.open).keyboardShortcut(",")
                }
                CommandGroup(replacing: .newItem) {}
                CommandGroup(after: .toolbar) {
                    Button("Reload") { store.selected?.reload() }.keyboardShortcut("r")
                    Button("Back") { store.selected?.goBack() }.keyboardShortcut("[")
                    Button("Forward") { store.selected?.goForward() }.keyboardShortcut("]")
                    Divider()
                    Button("Actual Size") { store.selected?.zoom(by: nil) }.keyboardShortcut("0")
                    Button("Zoom In") { store.selected?.zoom(by: 0.1) }.keyboardShortcut("=")
                    Button("Zoom Out") { store.selected?.zoom(by: -0.1) }.keyboardShortcut("-")
                    Divider()
                }
                CommandMenu("Services") {
                    ForEach(Array(store.controllers.enumerated()), id: \.element.config.id) { index, controller in
                        if index < 9 {
                            Button(controller.config.name) { store.select(controller.config.id) }
                                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                        } else {
                            Button(controller.config.name) { store.select(controller.config.id) }
                        }
                    }
                    Divider()
                    Button("Next Service") { store.selectAdjacent(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                    Button("Previous Service") { store.selectAdjacent(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
                    Divider()
                    Button("Open in Browser") { store.selected?.openInBrowser() }
                    Button("Copy URL") { store.selected?.copyURL() }.keyboardShortcut("c", modifiers: [.command, .shift])
                }
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        let store = ServiceStore.shared
        let sidebar = NSHostingView(rootView: SidebarView(store: store))
        sidebar.sizingOptions = []
        sidebar.appearance = NSAppearance(named: .darkAqua)
        let root = NSView()
        for view in [sidebar, store.container] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SidebarView.width),
            store.container.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            store.container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            store.container.topAnchor.constraint(equalTo: root.topAnchor),
            store.container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Switchboard"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 600, height: 400)
        window.delegate = self
        window.contentView = root
        window.center()
        window.setFrameAutosaveName("SwitchboardMain")

        store.start()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "r" else { return event }
            ServiceStore.shared.selected?.reload()
            return nil
        }
        window.makeKeyAndOrderFront(nil)
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        ServiceStore.shared.selected?.hasUnseenNotification = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let service = info["service"] as? String, let id = info["notification"] as? String else { return }
        await MainActor.run {
            showWindow()
            ServiceStore.shared.notificationClicked(service: service, notification: id)
        }
    }
}
