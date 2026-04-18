import UniformTypeIdentifiers

/// The set of UTTypes Reader can open.
enum MarkdownDocumentType {
    static var contentTypes: [UTType] {
        var out: [UTType] = []
        if let md = UTType("net.daringfireball.markdown") { out.append(md) }
        if let mdown = UTType(filenameExtension: "markdown") { out.append(mdown) }
        out.append(.plainText)
        out.append(.text)
        return out
    }

    static let fileExtensions: [String] = ["md", "markdown", "mdown", "mkd", "mkdn"]
}
