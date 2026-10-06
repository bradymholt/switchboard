import AppKit
import UserNotifications
import WebKit

@MainActor
final class ServiceStore: ObservableObject {
    static let shared = ServiceStore()

    @Published private(set) var controllers: [ServiceController] = []
    @Published private(set) var selectedID: String?
    @Published private(set) var configError: String?

    let container = WebContainerView()
    private var configDate: Date?
    private var watchTimer: Timer?

    var selected: ServiceController? { controllers.first { $0.config.id == selectedID } }

    func start() {
        reload()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, ConfigFile.modificationDate != self.configDate else { return }
                self.reload()
            }
        }
    }

    func reload() {
        configDate = ConfigFile.modificationDate
        let configs: [ServiceConfig]
        switch ConfigFile.load() {
        case .failure(let error):
            configError = "services.json: \(error.localizedDescription)"
            return
        case .success(let loaded):
            configError = nil
            configs = loaded
        }

        let existing = Dictionary(controllers.map { ($0.config.id, $0) }, uniquingKeysWith: { a, _ in a })
        controllers = configs.map { config in
            if let controller = existing[config.id], controller.config == config { return controller }
            let controller = ServiceController(config: config)
            controller.store = self
            return controller
        }
        let kept = Set(controllers.map(ObjectIdentifier.init))
        existing.values.filter { !kept.contains(ObjectIdentifier($0)) }.forEach { $0.tearDown() }

        if selected == nil {
            let last = UserDefaults.standard.string(forKey: "selectedService")
            select(controllers.contains { $0.config.id == last } ? last : controllers.first?.config.id)
        } else {
            container.show(controllers, selected: selectedID)
        }
        badgesChanged()
    }

    func select(_ id: String?) {
        selectedID = id
        UserDefaults.standard.set(id, forKey: "selectedService")
        selected?.hasUnseenNotification = false
        container.show(controllers, selected: id)
    }

    func selectAdjacent(_ offset: Int) {
        guard !controllers.isEmpty else { return }
        let index = controllers.firstIndex { $0.config.id == selectedID } ?? 0
        select(controllers[(index + offset + controllers.count) % controllers.count].config.id)
    }

    func badgesChanged() {
        let badges = controllers.map(\.badge)
        let total = badges.reduce(0) { $0 + $1.count }
        NSApp.dockTile.badgeLabel = total > 0 ? "\(total)" : badges.contains(.dot) ? "•" : nil
    }

    func serviceDidNotify(_ controller: ServiceController, id: String, title: String, body: String, silent: Bool) {
        let isFront = NSApp.isActive && selectedID == controller.config.id && container.window?.isVisible == true
        if isFront { return }
        controller.hasUnseenNotification = true

        let content = UNMutableNotificationContent()
        content.title = title
        if title != controller.config.name { content.subtitle = controller.config.name }
        content.body = body
        content.sound = silent ? nil : .default
        content.userInfo = ["service": controller.config.id, "notification": id]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func notificationClicked(service: String, notification: String) {
        guard let controller = controllers.first(where: { $0.config.id == service }) else { return }
        select(service)
        controller.notificationClicked(id: notification)
    }
}

final class WebContainerView: NSView {
    let findBar = FindBarView()
    private let content = NSView()
    private(set) var current: WKWebView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(content)
        addSubview(findBar)
        findBar.webView = { [weak self] in self?.current }
        findBar.onVisibilityChange = { [weak self] in self?.needsLayout = true }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let barHeight = findBar.isHidden ? 0 : FindBarView.height
        findBar.frame = NSRect(x: 0, y: bounds.height - FindBarView.height, width: bounds.width, height: FindBarView.height)
        content.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - barHeight)
    }

    func show(_ controllers: [ServiceController], selected: String?) {
        let keep = Set(controllers.map { ObjectIdentifier($0.webView) })
        content.subviews.filter { !keep.contains(ObjectIdentifier($0)) }.forEach { $0.removeFromSuperview() }
        current = nil
        for controller in controllers {
            let webView = controller.webView
            if webView.superview !== content {
                webView.frame = content.bounds
                webView.autoresizingMask = [.width, .height]
                content.addSubview(webView)
            }
            webView.isHidden = controller.config.id != selected
            if !webView.isHidden {
                current = webView
                if findBar.isHidden { window?.makeFirstResponder(webView) }
            }
        }
    }
}
