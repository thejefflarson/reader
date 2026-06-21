import AppKit
import Sparkle
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [MainWindowController] = []
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        if controllers.isEmpty {
            newDocument(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        _ = updaterController        // start the background update checker
        offerDefaultHandlerIfFirstLaunch()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updaterController.checkForUpdates(sender)
    }

    /// Prompt the user to symlink the bundled `reader` CLI script into a
    /// directory on PATH. We try the standard locations that don't require
    /// admin privileges before falling back to asking.
    @objc func installCommandLineTool(_ sender: Any?) {
        let fm = FileManager.default
        guard let bundled = Bundle.main.url(forResource: "reader", withExtension: nil) else {
            showAlert("The `reader` script is missing from this build of the app.",
                      informative: "Rebuild with `./scripts/build-app.sh` and try again.")
            return
        }

        let home = fm.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: "/usr/local/bin"),
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent("bin"),
        ]
        for dir in candidates {
            guard fm.isWritableFile(atPath: dir.path) else { continue }
            let target = dir.appendingPathComponent("reader")
            try? fm.removeItem(at: target)
            do {
                try fm.createSymbolicLink(at: target, withDestinationURL: bundled)
                showAlert("Installed `reader` at \(target.path)",
                          informative: "Run `reader path/to/file.md` from any shell to open a markdown file in Reader. If `\(target.path)` isn't on your PATH, add it to your shell profile.")
                return
            } catch {
                continue
            }
        }

        // Nothing writable — hand the user the source path so they can place it themselves.
        showAlert("Couldn't find a writable install location.",
                  informative: "Symlink this script to any directory on your PATH:\n\n\(bundled.path)")
    }

    private func showAlert(_ message: String, informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.runModal()
    }

    // MARK: - Default markdown handler

    /// The UTType the system uses for `.md` and friends. Files declared in
    /// `Info.plist`'s `UTImportedTypeDeclarations` resolve through this.
    private static let markdownUTI = "net.daringfireball.markdown"

    /// True when this build of Reader is the user's current default opener
    /// for markdown documents. Returns false on the simulator and on systems
    /// where no handler is registered yet.
    private func isDefaultMarkdownHandler() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let handler = LSCopyDefaultRoleHandlerForContentType(
                Self.markdownUTI as CFString, .editor
              )?.takeRetainedValue() as String?
        else { return false }
        return handler.caseInsensitiveCompare(bundleID) == .orderedSame
    }

    @objc func setAsDefaultMarkdownApp(_ sender: Any?) {
        guard let bundleID = Bundle.main.bundleIdentifier else {
            showAlert("Reader has no bundle identifier.",
                      informative: "This is an unsigned development build — install Reader.app to /Applications first.")
            return
        }
        let status = LSSetDefaultRoleHandlerForContentType(
            Self.markdownUTI as CFString,
            .editor,
            bundleID as CFString
        )
        if status == noErr {
            showAlert("Reader is now the default markdown app.",
                      informative: "Double-clicking a `.md` file in Finder will open it in Reader.")
        } else {
            showAlert("Couldn't set Reader as the default markdown app.",
                      informative: "Launch Services returned status \(status). Try setting it manually: right-click a `.md` file in Finder → Get Info → Open With → Reader → Change All…")
        }
    }

    /// On the very first launch (per-user), if Reader isn't already the
    /// default markdown handler, offer to make it so. The user's answer is
    /// remembered — we never nag a second time.
    private func offerDefaultHandlerIfFirstLaunch() {
        let key = "ReaderDidOfferDefaultHandler"
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)

        // Skip if we're already the handler (e.g. user previously set it
        // manually, or this is a re-install).
        guard !isDefaultMarkdownHandler() else { return }

        let alert = NSAlert()
        alert.messageText = "Open `.md` files in Reader by default?"
        alert.informativeText = "Reader can register as your default markdown editor so double-clicking any `.md` file opens it here. You can change this any time from the Reader menu."
        alert.addButton(withTitle: "Make Default")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            setAsDefaultMarkdownApp(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - File handling

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        // Validate the extension before accepting the path. CLI callers bypass
        // NSOpenPanel's content-type filter, so we must enforce it here to
        // prevent arbitrary files from being fed to the editor / Recent Documents.
        let url = URL(fileURLWithPath: filename)
        let allowedExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
        guard allowedExtensions.contains(url.pathExtension.lowercased()) else { return false }
        openURL(url)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(openURL)
    }

    private func openURL(_ url: URL) {
        if let existing = controllers.first(where: { $0.window?.representedURL == url }) {
            existing.showWindow(nil)
            return
        }
        let controller: MainWindowController
        if let empty = controllers.first(where: { $0.markdown.isEmpty && $0.window?.representedURL == nil }) {
            controller = empty
        } else {
            controller = MainWindowController()
            controllers.append(controller)
        }
        controller.showWindow(nil)
        controller.open(url: url)
    }

    // MARK: - Menu actions

    @objc func newDocument(_ sender: Any?) {
        let controller = MainWindowController()
        controllers.append(controller)
        controller.showWindow(nil)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MarkdownDocumentType.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            panel.urls.forEach { self?.openURL($0) }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        frontController()?.save()
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        frontController()?.saveAs()
    }

    private func frontController() -> MainWindowController? {
        if let key = NSApp.keyWindow,
           let controller = controllers.first(where: { $0.window === key }) {
            return controller
        }
        return controllers.last
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if let last = controllers.last {
                last.showWindow(nil)
            } else {
                newDocument(nil)
            }
        }
        return true
    }

    // MARK: - Menu bar

    private func buildMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Reader", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Set as Default Markdown App", action: #selector(setAsDefaultMarkdownApp(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Install Command Line Tool…", action: #selector(installCommandLineTool(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Reader", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Reader", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New", action: #selector(newDocument(_:)), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        let recentMenuItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recentMenuItem.submenu = recentMenu
        fileMenu.addItem(recentMenuItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        let saveAs = NSMenuItem(title: "Save As…", action: #selector(saveDocumentAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAs)
        fileMenuItem.submenu = fileMenu

        // Edit menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findMenu.addItem(withTitle: "Find…", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "f").tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        findMenu.addItem(withTitle: "Find Next", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g").tag = Int(NSFindPanelAction.next.rawValue)
        let findPrev = NSMenuItem(title: "Find Previous", action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: "g")
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        findPrev.tag = Int(NSFindPanelAction.previous.rawValue)
        findMenu.addItem(findPrev)
        find.submenu = findMenu
        editMenu.addItem(find)
        editMenuItem.submenu = editMenu

        // View menu
        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(makeItem(
            "Preview",
            action: #selector(EditorTextView.togglePreview(_:)),
            key: "p",
            modifiers: [.command, .shift]
        ))
        viewMenuItem.submenu = viewMenu

        // Format menu
        let formatMenuItem = NSMenuItem()
        mainMenu.addItem(formatMenuItem)
        let formatMenu = NSMenu(title: "Format")
        formatMenu.addItem(makeItem("Bold", action: #selector(EditorTextView.toggleBold(_:)), key: "b"))
        formatMenu.addItem(makeItem("Italic", action: #selector(EditorTextView.toggleItalic(_:)), key: "i"))
        formatMenu.addItem(makeItem("Inline Code", action: #selector(EditorTextView.toggleCode(_:)), key: "k"))
        formatMenu.addItem(makeItem("Strikethrough", action: #selector(EditorTextView.toggleStrike(_:)), key: "x", modifiers: [.command, .shift]))
        formatMenu.addItem(makeItem("Link…", action: #selector(EditorTextView.insertLink(_:)), key: "k", modifiers: [.command, .shift]))
        formatMenu.addItem(.separator())
        formatMenu.addItem(makeItem("No Heading", action: #selector(EditorTextView.applyHeading0(_:)), key: "0"))
        formatMenu.addItem(makeItem("Heading 1", action: #selector(EditorTextView.applyHeading1(_:)), key: "1"))
        formatMenu.addItem(makeItem("Heading 2", action: #selector(EditorTextView.applyHeading2(_:)), key: "2"))
        formatMenu.addItem(makeItem("Heading 3", action: #selector(EditorTextView.applyHeading3(_:)), key: "3"))
        formatMenu.addItem(.separator())
        formatMenu.addItem(makeItem("Bulleted List", action: #selector(EditorTextView.toggleUnorderedList(_:)), key: "l", modifiers: [.command, .shift]))
        formatMenu.addItem(makeItem("Blockquote", action: #selector(EditorTextView.toggleBlockquote(_:)), key: "'", modifiers: [.command, .shift]))
        formatMenuItem.submenu = formatMenu

        // Window menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    private func makeItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
