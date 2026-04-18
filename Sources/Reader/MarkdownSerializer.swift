import AppKit

/// Converts `NSAttributedString` produced by other apps (e.g. HTML/RTF pastes)
/// into plain markdown text suitable for insertion into the editor.
///
/// For content originating in Reader itself, the underlying string is already
/// markdown — no conversion needed.
enum MarkdownSerializer {
    static func markdown(from attributed: NSAttributedString) -> String {
        let full = NSRange(location: 0, length: attributed.length)
        var out = ""

        attributed.enumerateAttributes(in: full, options: []) { attrs, range, _ in
            let sub = (attributed.string as NSString).substring(with: range)
            out += wrap(sub, attributes: attrs)
        }
        return collapseWhitespace(out)
    }

    private static func wrap(_ text: String, attributes: [NSAttributedString.Key: Any]) -> String {
        if text.isEmpty { return text }

        var content = text

        if let url = attributes[.link] as? URL {
            return "[\(content)](\(url.absoluteString))"
        }
        if let urlString = attributes[.link] as? String, let url = URL(string: urlString) {
            return "[\(content)](\(url.absoluteString))"
        }

        let font = attributes[.font] as? NSFont
        let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
        let isBold = traits.contains(.boldFontMask)
        let isItalic = traits.contains(.italicFontMask)
        let isMono = font?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false

        if attributes[.strikethroughStyle] != nil {
            content = "~~\(content)~~"
        }
        if isMono {
            // Inline-only; assume the paste is not a code block
            content = "`\(content)`"
        }
        if isBold && isItalic {
            content = "***\(content)***"
        } else if isBold {
            content = "**\(content)**"
        } else if isItalic {
            content = "*\(content)*"
        }
        return content
    }

    private static func collapseWhitespace(_ text: String) -> String {
        // Preserve paragraph breaks (\n\n+) but collapse runs of three or more
        // newlines, which HTML paste tends to introduce.
        var result = ""
        var newlineRun = 0
        for ch in text {
            if ch == "\n" {
                newlineRun += 1
                if newlineRun <= 2 { result.append(ch) }
            } else {
                newlineRun = 0
                result.append(ch)
            }
        }
        return result
    }
}
