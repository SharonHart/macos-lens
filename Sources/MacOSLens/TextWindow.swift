import AppKit

final class TextWindow: NSWindow {
    private let textView = NSTextView()
    private let action: (String, String) -> Void

    init(text: String, action: @escaping (String, String) -> Void) {
        self.action = action
        super.init(contentRect: NSRect(x: 0, y: 0, width: 660, height: 440),
                   styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = "Recognized text — Apple Vision (local)"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 600, height: 300)
        let root = contentView!
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 72, width: 620, height: 345))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.frame = scroll.contentView.bounds
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = .systemFont(ofSize: 17)
        textView.string = text
        scroll.documentView = textView
        root.addSubview(scroll)
        let label = NSTextField(labelWithString: "Select text for an action, or use all text when nothing is selected.")
        label.frame = NSRect(x: 20, y: 46, width: 620, height: 20)
        root.addSubview(label)
        for (index, title) in ["Copy", "Search", "Translate", "Listen", "Stop"].enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(performAction(_:)))
            button.frame = NSRect(x: 20 + index * 120, y: 10, width: 110, height: 30)
            root.addSubview(button)
        }
        center()
    }

    @objc private func performAction(_ sender: NSButton) {
        let range = textView.selectedRange()
        let text = range.length > 0 ? (textView.string as NSString).substring(with: range) : textView.string
        action(sender.title, text)
    }
}
