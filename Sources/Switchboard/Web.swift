import AppKit
import CryptoKit
import WebKit

enum Badge: Equatable {
    case none, dot, count(Int)

    var count: Int {
        if case .count(let n) = self { return n }
        return 0
    }

    init(fromTitle title: String) {
        if let match = title.firstMatch(of: Badge.titleCount), let n = Int(match.output[1].substring ?? ""), n > 0 {
            self = .count(n)
        } else if let first = title.first, "*•●!".contains(first) {
            self = .dot
        } else {
            self = .none
        }
    }

    init(fromScriptValue value: Any?) {
        guard let number = value as? NSNumber else { self = .none; return }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            self = number.boolValue ? .dot : .none
        } else if number.intValue < 0 {
            self = .dot
        } else {
            self = number.intValue > 0 ? .count(number.intValue) : .none
        }
    }

    private static let titleCount = try! Regex(#"\((\d+)\)"#)
}

@MainActor
enum DataStores {
    private static var cache: [String: WKWebsiteDataStore] = [:]

    static func store(for profile: String?) -> WKWebsiteDataStore {
        let name = profile ?? "default"
        if let store = cache[name] { return store }
        let store = WKWebsiteDataStore(forIdentifier: uuid(for: name))
        cache[name] = store
        return store
    }

    private static func uuid(for name: String) -> UUID {
        let b = Array(SHA256.hash(data: Data("switchboard-profile:\(name)".utf8)))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

enum WebRouting {
    /// Tracks the installed Safari so sites see a current, supported browser (Google sign-in rejects unknown webviews).
    static let chromeUserAgent: String = {
        let version = Bundle(path: "/Applications/Google Chrome.app")?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "141.0.0.0"
        let major = version.split(separator: ".").first ?? "141"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(major).0.0.0 Safari/537.36"
    }()

    static func userAgent(for setting: String?) -> String? {
        switch setting?.lowercased() {
        case nil, "", "safari": return nil
        case "chrome": return chromeUserAgent
        default: return setting
        }
    }

    static let userAgentSuffix: String = {
        let version = Bundle(path: "/Applications/Safari.app")?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "26.0"
        return "Version/\(version) Safari/605.1.15"
    }()

    static let inAppSchemes: Set<String> = ["http", "https", "about", "blob", "data", "javascript"]
    static let authDomains: Set<String> = ["google.com", "microsoftonline.com", "microsoft.com", "live.com", "apple.com", "okta.com", "auth0.com", "onelogin.com"]

    static let authOnlyDomains: Set<String> = ["microsoftonline.com", "okta.com", "auth0.com", "onelogin.com"]

    static func isSignInPage(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), let base = baseDomain(host), authDomains.contains(base) else { return false }
        return authOnlyDomains.contains(base) || ["accounts.", "login.", "signin.", "auth.", "appleid.", "idmsa."].contains { host.hasPrefix($0) }
    }

    /// Google wraps outbound links (Calendar, Gmail, Docs) in `google.com/url?q=…`, which serves an
    /// HTML redirect page rather than a 302. Route on the destination so it isn't mistaken for a Google page.
    static func unwrappingRedirector(_ url: URL) -> URL {
        guard let host = url.host?.lowercased(), baseDomain(host) == "google.com", url.path == "/url",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let target = items.first(where: { $0.name == "q" || $0.name == "url" })?.value,
              let destination = URL(string: target), destination.host != nil else { return url }
        return destination
    }

    static func baseDomain(_ host: String?) -> String? {
        guard let parts = host?.lowercased().split(separator: "."), parts.count >= 2 else { return host }
        let secondLevel = ["co", "com", "org", "net", "ac", "gov", "edu"]
        let take = parts.count >= 3 && parts.last!.count == 2 && secondLevel.contains(String(parts[parts.count - 2])) ? 3 : 2
        return parts.suffix(take).joined(separator: ".")
    }
}

@MainActor
final class ServiceController: NSObject, ObservableObject {
    let config: ServiceConfig
    let webView: WKWebView
    weak var store: ServiceStore?

    @Published private(set) var badge: Badge = .none
    @Published private(set) var icon: NSImage?
    var hasUnseenNotification = false { didSet { updateBadge() } }

    private var titleBadge: Badge = .none
    private var appBadge: Badge?
    private var scriptBadge: Badge?
    private var titleObservation: NSKeyValueObservation?
    private var badgeTimer: Timer?
    private var popups: [PopupWindow] = []
    private var notificationFrames: [String: WKFrameInfo] = [:]
    private var downloads: [ObjectIdentifier: URL] = [:]
    private var iconFetched = false

    init(config: ServiceConfig) {
        self.config = config
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = DataStores.store(for: config.profile)
        configuration.applicationNameForUserAgent = WebRouting.userAgentSuffix
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(
            WKUserScript(source: Scripts.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let handler = ScriptHandler()
        configuration.userContentController.add(handler, name: "switchboard")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()

        handler.controller = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        webView.customUserAgent = WebRouting.userAgent(for: config.userAgent)
        webView.allowsBackForwardNavigationGestures = true
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.titleChanged(webView.title ?? "") }
        }
        if config.badge != nil {
            badgeTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluateBadgeScript() }
            }
        }
        loadIcon()
        webView.load(URLRequest(url: config.url))
    }

    func tearDown() {
        badgeTimer?.invalidate()
        titleObservation = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "switchboard")
        webView.removeFromSuperview()
        popups.forEach { $0.close() }
    }

    // MARK: Actions

    func reload() { webView.reload() }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func goHome() { webView.load(URLRequest(url: config.url)) }
    func zoom(by delta: CGFloat?) { webView.pageZoom = delta.map { max(0.5, min(3, webView.pageZoom + $0)) } ?? 1 }

    func openInBrowser() {
        NSWorkspace.shared.open(webView.url ?? config.url)
    }

    func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((webView.url ?? config.url).absoluteString, forType: .string)
    }

    func notificationClicked(id: String) {
        let script = "window.__switchboardNotificationClicked && window.__switchboardNotificationClicked(\(jsString(id)))"
        webView.evaluateJavaScript(script, in: notificationFrames[id], in: .page) { _ in }
    }

    // MARK: Badges

    private func titleChanged(_ title: String) {
        titleBadge = Badge(fromTitle: title)
        updateBadge()
    }

    private func evaluateBadgeScript() {
        guard let script = config.badge else { return }
        webView.evaluateJavaScript("(() => { try { return (\(script)); } catch (_) { return null; } })()") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.scriptBadge = Badge(fromScriptValue: result)
                self.updateBadge()
            }
        }
    }

    private func updateBadge() {
        var next = scriptBadge ?? appBadge ?? titleBadge
        if next == .none && hasUnseenNotification { next = .dot }
        guard next != badge else { return }
        badge = next
        store?.badgesChanged()
    }

    fileprivate func handle(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "notification":
            let id = body["id"] as? String ?? UUID().uuidString
            if notificationFrames.count > 100 { notificationFrames.removeAll() }
            notificationFrames[id] = message.frameInfo
            store?.serviceDidNotify(self, id: id,
                                    title: body["title"] as? String ?? config.name,
                                    body: body["body"] as? String ?? "",
                                    silent: body["silent"] as? Bool ?? false)
        case "badge":
            appBadge = Badge(fromScriptValue: body["count"])
            updateBadge()
        default:
            break
        }
    }

    // MARK: Icons

    private var cachedIconURL: URL {
        let safe = config.name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Switchboard/icons/\(safe).png")
    }

    private func loadIcon() {
        if let custom = config.icon {
            if custom.hasPrefix("http"), let url = URL(string: custom) {
                Task { icon = await Self.downloadImage(url) }
            } else {
                icon = NSImage(contentsOfFile: (custom as NSString).expandingTildeInPath)
            }
            iconFetched = true
        } else {
            icon = NSImage(contentsOf: cachedIconURL)
        }
    }

    private func fetchIconIfNeeded() {
        guard !iconFetched else { return }
        guard webView.url?.host == config.url.host else {
            if icon == nil, let origin = URL(string: "/", relativeTo: config.url)?.absoluteURL {
                var lookup = URLComponents(string: "https://t1.gstatic.com/faviconV2?client=SOCIAL&type=FAVICON&fallback_opts=TYPE,SIZE,URL&size=128")!
                lookup.queryItems?.append(URLQueryItem(name: "url", value: origin.absoluteString))
                let candidates = [origin.appending(path: "favicon.ico"), lookup.url!]
                Task {
                    for url in candidates where icon == nil {
                        icon = await Self.downloadImage(url)
                    }
                }
            }
            return
        }
        iconFetched = true
        Task {
            let result = try? await webView.callAsyncJavaScript(Scripts.iconCandidates, contentWorld: .defaultClient)
            for candidate in (result as? [String]) ?? [] {
                guard let url = URL(string: candidate), let image = await Self.downloadImage(url) else { continue }
                icon = image
                try? FileManager.default.createDirectory(at: cachedIconURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: cachedIconURL)
                }
                return
            }
        }
    }

    private static func downloadImage(_ url: URL) async -> NSImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              let image = NSImage(data: data), image.isValid, image.size.width >= 16 else { return nil }
        return image
    }

    // MARK: Routing

    func allowsInApp(_ url: URL) -> Bool {
        guard let base = WebRouting.baseDomain(url.host) else { return true }
        return base == WebRouting.baseDomain(config.url.host) || WebRouting.isSignInPage(url)
    }

    /// Returns true when the URL was handed to another app and the web view should not load it.
    func routeExternally(_ url: URL, linkActivated: Bool) -> Bool {
        if !WebRouting.inAppSchemes.contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
            return true
        }
        guard linkActivated else { return false }
        let destination = WebRouting.unwrappingRedirector(url)
        if let target = store?.controller(forHost: destination.host, from: self) {
            store?.open(destination, in: target)
            return true
        }
        if !allowsInApp(destination) {
            NSWorkspace.shared.open(destination)
            return true
        }
        return false
    }

    fileprivate func popupClosed(_ popup: PopupWindow) {
        popups.removeAll { $0 === popup }
    }
}

extension ServiceController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if action.shouldPerformDownload { return .download }
        guard let url = action.request.url, action.targetFrame != nil else { return .allow }
        let isMain = action.targetFrame?.isMainFrame ?? true
        return routeExternally(url, linkActivated: isMain && action.navigationType == .linkActivated) ? .cancel : .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        fetchIconIfNeeded()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }
}

extension ServiceController: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let name = suggestedFilename as NSString
        var destination = folder.appending(path: suggestedFilename)
        var n = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            let stem = "\(name.deletingPathExtension) (\(n))"
            destination = folder.appending(path: name.pathExtension.isEmpty ? stem : "\(stem).\(name.pathExtension)")
            n += 1
        }
        downloads[ObjectIdentifier(download)] = destination
        return destination
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: destination.path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
    }
}

extension ServiceController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, url.scheme != "about", !url.absoluteString.isEmpty,
           routeExternally(url, linkActivated: true) {
            return nil
        }
        if action.navigationType == .linkActivated, let url = action.request.url, WebRouting.isSignInPage(url) {
            self.webView.load(action.request)
            return nil
        }
        let popup = PopupWindow(configuration: configuration, features: windowFeatures, owner: self)
        popups.append(popup)
        let url = action.request.url?.absoluteString ?? ""
        if url.isEmpty || url == "about:blank" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak popup] in popup?.revealIfPending() }
        }
        return popup.webView
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = config.name
        alert.informativeText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = config.name
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        return panel.runModal() == .OK ? panel.urls : nil
    }

    func webView(_ webView: WKWebView, decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
                 initiatedBy frame: WKFrameInfo, type: WKMediaCaptureType) async -> WKPermissionDecision {
        .grant
    }
}

@MainActor
private final class ScriptHandler: NSObject, WKScriptMessageHandler {
    weak var controller: ServiceController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        controller?.handle(message)
    }
}

/// Window for `window.open()` (OAuth, "open in new window"). Stays hidden until it commits an in-app
/// page, so link-redirect popups that bounce to the system browser never flash on screen.
@MainActor
final class PopupWindow: NSObject {
    let webView: WKWebView
    private let window: NSWindow
    private weak var owner: ServiceController?
    private var titleObservation: NSKeyValueObservation?
    private var closed = false

    init(configuration: WKWebViewConfiguration, features: WKWindowFeatures, owner: ServiceController) {
        let frame = NSRect(x: 0, y: 0, width: features.width?.doubleValue ?? 900, height: features.height?.doubleValue ?? 720)
        webView = WKWebView(frame: frame, configuration: configuration)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        self.owner = owner
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        webView.customUserAgent = owner.webView.customUserAgent
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.window.title = webView.title ?? "" }
        }
    }

    /// Pages like Slack's huddle open `about:blank` and render into it from the opener.
    func revealIfPending() {
        guard !closed, !window.isVisible else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard !closed else { return }
        closed = true
        titleObservation = nil
        window.orderOut(nil)
        window.delegate = nil
        owner?.popupClosed(self)
    }
}

extension PopupWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) { close() }
}

extension PopupWindow: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, action.targetFrame?.isMainFrame ?? false, let owner else { return .allow }
        if owner.routeExternally(url, linkActivated: !window.isVisible || action.navigationType == .linkActivated) {
            if !window.isVisible { close() }
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !window.isVisible, !closed, ["http", "https"].contains(webView.url?.scheme) else { return }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

extension PopupWindow: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        owner?.webView(webView, createWebViewWith: configuration, for: action, windowFeatures: windowFeatures)
    }

    func webViewDidClose(_ webView: WKWebView) {
        window.close()
        close()
    }
}

private func jsString(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    return data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
}

