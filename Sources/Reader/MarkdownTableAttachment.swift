import AppKit
import SwiftUI

/// A SwiftUI rendering of a markdown table. Headers in bold, body rows in
/// plain prose; subtle separator between header and body, a quiet hairline
/// border around the whole grid. Fills the available text-column width;
/// cells share that width equally and wrap their text as needed.
struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                    Text(h)
                        .font(.headline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider().gridCellColumns(max(headers.count, 1))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        Text(cell)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
        )
        .font(Font(Theme.bodyFont))
    }
}

// MARK: - Attachment

/// Carries the parsed table data so the view provider can build the
/// SwiftUI view. Subclassing `NSTextAttachment` lets us pass arbitrary
/// data to the provider via the attachment instance.
final class MarkdownTableAttachment: NSTextAttachment {
    let headers: [String]
    let rows: [[String]]

    init(headers: [String], rows: [[String]]) {
        self.headers = headers
        self.rows = rows
        super.init(data: nil, ofType: nil)
        // `NSTextAttachmentViewProvider` is consulted only in TextKit 2;
        // the class name is resolved at runtime from the module's
        // Swift-mangled symbol table.
        self.allowsTextAttachmentView = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func viewProvider(
        for parentView: NSView?,
        location: NSTextLocation,
        textContainer: NSTextContainer?
    ) -> NSTextAttachmentViewProvider? {
        let provider = MarkdownTableViewProvider(
            textAttachment: self,
            parentView: parentView,
            textLayoutManager: textContainer?.textLayoutManager,
            location: location
        )
        provider.tracksTextAttachmentViewBounds = true
        return provider
    }
}

// MARK: - View provider

/// Hosts the SwiftUI `MarkdownTableView` inside an `NSHostingView`. The
/// view sizes to its content; the bounds are reported back to the layout
/// manager so the surrounding text reflows around the table.
final class MarkdownTableViewProvider: NSTextAttachmentViewProvider {
    override func loadView() {
        guard let attachment = textAttachment as? MarkdownTableAttachment else {
            view = NSView()
            return
        }
        let host = NSHostingView(rootView: MarkdownTableView(
            headers: attachment.headers,
            rows: attachment.rows
        ))
        host.translatesAutoresizingMaskIntoConstraints = false
        view = host
    }

    override func attachmentBounds(
        for attributes: [NSAttributedString.Key: Any],
        location: NSTextLocation,
        textContainer: NSTextContainer?,
        proposedLineFragment: CGRect,
        position: CGPoint
    ) -> CGRect {
        guard let view = view else { return .zero }
        // Fill the text column. Cells share the width equally and wrap
        // their text as needed; the SwiftUI hosting view reports its
        // wanted height for that fixed width via `fittingSize`.
        let width = max(0, textContainer?.size.width ?? proposedLineFragment.width)
        view.frame = NSRect(x: 0, y: 0, width: width, height: 10_000)
        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height
        return CGRect(x: 0, y: 0, width: width, height: height)
    }
}
