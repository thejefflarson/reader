import AppKit

/// Owns the window, the editor, and the bottom dock.
///
/// Kept intentionally spare: one unified window, no sidebar, no preview
/// pane, no top toolbar — the editor *is* the preview, and the eye sees
/// only text. The bottom dock carries every control and every readout.
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let editor: EditorTextView
    private let bottomBar = BottomBar()
    private let scrollView: NSScrollView
    private var currentFileURL: URL?
    private var isDirty = false
    private var observer: NSObjectProtocol?
    private var selectionObserver: NSObjectProtocol?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 740),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Untitled"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 400)
        window.center()
        window.backgroundColor = Theme.editorBackground
        window.isMovableByWindowBackground = true
        window.toolbar = nil

        // ScrollView + EditorTextView
        let scroll = NSScrollView(frame: .zero)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false

        let container = NSTextContainer(containerSize: NSSize(
            width: Theme.measure,
            height: .greatestFiniteMagnitude
        ))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        let textView = EditorTextView(frame: .zero, textContainer: container)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width] as NSView.AutoresizingMask
        textView.textContainerInset = NSSize(
            width: Theme.editorPadding.left,
            height: Theme.editorPadding.top
        )

        scroll.documentView = textView
        self.scrollView = scroll
        self.editor = textView

        super.init(window: window)
        window.delegate = self

        assembleContent()
        centerEditorContainer()

        observer = NotificationCenter.default.addObserver(
            forName: .editorTextDidChange,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            self?.didEdit()
        }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: .editorSelectionDidChange,
            object: textView,
            queue: .main
        ) { [weak self] _ in
            self?.updateActiveFormats()
        }

        bottomBar.update(for: "", documentName: nil)
        window.makeFirstResponder(textView)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
    }

    private func updateActiveFormats() {
        let state = editor.currentFormatState()
        var active: Set<BottomBar.Control> = []
        if state.bold { active.insert(.bold) }
        if state.italic { active.insert(.italic) }
        if state.code { active.insert(.code) }
        if state.heading { active.insert(.heading) }
        if state.list { active.insert(.list) }
        if state.quote { active.insert(.quote) }
        if state.link { active.insert(.link) }
        bottomBar.setActiveFormats(active)
    }

    override func showWindow(_ sender: Any?) {
        guard let window = window else { return }
        window.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Layout

    private func assembleContent() {
        guard let window = window else { return }
        let content = NSView(frame: window.contentLayoutRect)
        content.autoresizingMask = [.width, .height]
        content.translatesAutoresizingMaskIntoConstraints = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scrollView)
        content.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

            bottomBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        window.contentView = content
        content.layoutSubtreeIfNeeded()
    }

    private func centerEditorContainer() {
        guard let container = editor.textContainer else { return }
        let clipView = scrollView.contentView
        let width = min(clipView.bounds.width, Theme.measure)
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)

        let horizontalInset = max(
            Theme.editorPadding.left,
            (clipView.bounds.width - width) / 2
        )
        editor.textContainerInset = NSSize(
            width: horizontalInset,
            height: Theme.editorPadding.top
        )
    }

    func windowDidResize(_ notification: Notification) {
        centerEditorContainer()
        editor.reapplyStyling()
    }

    // MARK: - Document model

    var markdown: String {
        get { editor.string }
        set {
            editor.string = newValue
            editor.reapplyStyling()
            isDirty = false
            updateTitle()
            bottomBar.update(for: newValue, documentName: displayName)
        }
    }

    func open(url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            currentFileURL = url
            markdown = content
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = MarkdownDocumentType.contentTypes
        panel.nameFieldStringValue = currentFileURL?.lastPathComponent ?? "Untitled.md"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.writeContents(to: url)
            self.currentFileURL = url
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            self.isDirty = false
            self.updateTitle()
        }
    }

    func save() {
        guard let url = currentFileURL else { saveAs(); return }
        writeContents(to: url)
        isDirty = false
        updateTitle()
    }

    private func writeContents(to url: URL) {
        // Always write the markdown source, even if currently in preview mode.
        let source = editor.markdownSource ?? editor.string
        do {
            try source.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func didEdit() {
        if !editor.isPreviewing, !isDirty {
            isDirty = true
            updateTitle()
        }
        bottomBar.setPreviewing(editor.isPreviewing)
        let sourceText = editor.isPreviewing
            ? (editor.markdownSource ?? editor.string)
            : editor.string
        bottomBar.update(for: sourceText, documentName: displayName)
        updateActiveFormats()
    }

    private var displayName: String {
        currentFileURL?.lastPathComponent ?? "Untitled"
    }

    private func updateTitle() {
        window?.title = displayName
        window?.isDocumentEdited = isDirty
        if let url = currentFileURL {
            window?.representedURL = url
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(displayName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: save(); return !isDirty
        case .alertSecondButtonReturn: return false
        default: return true
        }
    }
}
