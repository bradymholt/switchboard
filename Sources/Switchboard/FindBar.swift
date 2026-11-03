import AppKit
import WebKit

@MainActor
final class FindBarView: NSVisualEffectView, NSSearchFieldDelegate {
    static let height: CGFloat = 36

    var webView: () -> WKWebView? = { nil }
    var onVisibilityChange: () -> Void = {}

    private let field = NSSearchField()
    private let status = NSTextField(labelWithString: "Not found")

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .headerView
        blendingMode = .withinWindow
        isHidden = true

        field.delegate = self
        field.placeholderString = "Find in page"
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.target = self
        field.action = #selector(textChanged)
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell?.target = self
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell?.action = #selector(hide)

        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.isHidden = true

        let previous = button("chevron.up", "Find Previous", #selector(findPrevious))
        let next = button("chevron.down", "Find Next", #selector(findNext))
        let done = NSButton(title: "Done", target: self, action: #selector(hide))
        done.bezelStyle = .accessoryBarAction
        done.controlSize = .small

        let separator = NSBox()
        separator.boxType = .separator

        for view in [field, status, previous, next, done, separator] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.widthAnchor.constraint(equalToConstant: 260),
            status.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 10),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            done.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            done.centerYAnchor.constraint(equalTo: centerYAnchor),
            next.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -12),
            next.centerYAnchor.constraint(equalTo: centerYAnchor),
            previous.trailingAnchor.constraint(equalTo: next.leadingAnchor, constant: -4),
            previous.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func button(_ symbol: String, _ label: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.toolTip = label
        return button
    }

    func show() {
        if isHidden {
            isHidden = false
            onVisibilityChange()
        }
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc func hide() {
        guard !isHidden else { return }
        isHidden = true
        status.isHidden = true
        onVisibilityChange()
        if let webView = webView() { window?.makeFirstResponder(webView) }
    }

    @objc func findNext() { find(backwards: false) }
    @objc func findPrevious() { find(backwards: true) }
    @objc private func textChanged() { find(backwards: false) }

    private func find(backwards: Bool) {
        let text = field.stringValue
        guard !text.isEmpty, let webView = webView() else {
            status.isHidden = true
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        Task { @MainActor in
            guard let result = try? await webView.find(text, configuration: configuration) else { return }
            guard field.stringValue == text else { return }
            status.isHidden = result.matchFound
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }
}
