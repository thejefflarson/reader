import AppKit

/// The only chrome in the window. Format buttons on the left, stats on the
/// right. No blur, no divider — the bar is indistinguishable from the page
/// until the reader notices it. Active format buttons burn a striking
/// scarlet (`Theme.activeAccent`) so the writer can see at a glance what
/// their cursor is inside of.
final class BottomBar: NSView {
    enum Control: CaseIterable {
        case heading, bold, italic, code, link, list, quote

        var symbol: String {
            switch self {
            case .heading: return "textformat.size"
            case .bold:    return "bold"
            case .italic:  return "italic"
            case .code:    return "chevron.left.forwardslash.chevron.right"
            case .link:    return "link"
            case .list:    return "list.bullet"
            case .quote:   return "text.quote"
            }
        }

        var label: String {
            switch self {
            case .heading: return "Heading"
            case .bold:    return "Bold"
            case .italic:  return "Italic"
            case .code:    return "Code"
            case .link:    return "Link"
            case .list:    return "List"
            case .quote:   return "Quote"
            }
        }

        var action: Selector {
            switch self {
            case .heading: return #selector(EditorTextView.applyHeading2(_:))
            case .bold:    return #selector(EditorTextView.toggleBold(_:))
            case .italic:  return #selector(EditorTextView.toggleItalic(_:))
            case .code:    return #selector(EditorTextView.toggleCode(_:))
            case .link:    return #selector(EditorTextView.insertLink(_:))
            case .list:    return #selector(EditorTextView.toggleUnorderedList(_:))
            case .quote:   return #selector(EditorTextView.toggleBlockquote(_:))
            }
        }
    }

    private let formatStack = NSStackView()
    private let statsLabel = NSTextField(labelWithString: "")
    private let filenameLabel = NSTextField(labelWithString: "")
    private let previewButton = NSButton()
    private var controlButtons: [Control: NSButton] = [:]

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 34)
    }

    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.editorBackground.cgColor

        formatStack.orientation = .horizontal
        formatStack.spacing = 2
        formatStack.alignment = .centerY
        formatStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(formatStack)

        for kind in Control.allCases {
            let btn = makeFormatButton(kind: kind)
            controlButtons[kind] = btn
            formatStack.addArrangedSubview(btn)
        }

        for label in [statsLabel, filenameLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.font = Theme.uiFont
            label.textColor = Theme.syntaxColor
            label.isBezeled = false
            label.isEditable = false
            label.drawsBackground = false
            addSubview(label)
        }
        statsLabel.alignment = .right
        filenameLabel.alignment = .right
        filenameLabel.textColor = Theme.secondaryColor

        configurePreviewButton()
        addSubview(previewButton)

        NSLayoutConstraint.activate([
            formatStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            formatStack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            filenameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            filenameLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            statsLabel.trailingAnchor.constraint(equalTo: filenameLabel.leadingAnchor, constant: -14),
            statsLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            previewButton.leadingAnchor.constraint(
                equalTo: formatStack.trailingAnchor, constant: 12),
            previewButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
    }

    override func updateLayer() {
        super.updateLayer()
        layer?.backgroundColor = Theme.editorBackground.cgColor
    }

    private func makeFormatButton(kind: Control) -> NSButton {
        let image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.label)
        let button = NSButton(image: image ?? NSImage(), target: nil, action: kind.action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = kind.label
        button.contentTintColor = Theme.syntaxColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }

    private func configurePreviewButton() {
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        previewButton.bezelStyle = .accessoryBar
        previewButton.isBordered = false
        previewButton.action = #selector(EditorTextView.togglePreview(_:))
        previewButton.target = nil
        setPreviewing(false)
    }

    private func applyPreviewLabel(active: Bool) {
        let label = active ? "Edit" : "Preview"
        let symbol = active ? "pencil" : "eye"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        let tint = active ? Theme.activeAccent : Theme.syntaxColor
        let title = NSAttributedString(
            string: " " + label,
            attributes: [
                .font: Theme.uiFont,
                .foregroundColor: tint,
            ]
        )
        previewButton.image = img
        previewButton.imagePosition = .imageLeading
        previewButton.attributedTitle = title
        previewButton.contentTintColor = tint
        previewButton.toolTip = active
            ? "Back to editing (⇧⌘P)"
            : "Preview — hide markdown syntax (⇧⌘P)"
    }

    func setPreviewing(_ active: Bool) {
        applyPreviewLabel(active: active)
        formatStack.alphaValue = active ? 0.35 : 1.0
        for (_, btn) in controlButtons { btn.isEnabled = !active }
    }

    /// The currently-active format state at the editor's caret / selection.
    /// Matching buttons burn in `activeAccent`.
    func setActiveFormats(_ formats: Set<Control>) {
        for (kind, btn) in controlButtons {
            btn.contentTintColor = formats.contains(kind)
                ? Theme.activeAccent
                : Theme.syntaxColor
        }
    }

    func update(for text: String, documentName: String?) {
        let words = countWords(text)
        let chars = text.count
        let minutes = max(1, Int((Double(words) / 230.0).rounded()))
        statsLabel.stringValue = "\(words)w · \(chars)c · ~\(minutes)m"
        filenameLabel.stringValue = documentName ?? ""
    }

    private func countWords(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .localized]
        ) { _, _, _, _ in
            count += 1
        }
        return count
    }
}
