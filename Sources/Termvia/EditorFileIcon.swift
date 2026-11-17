import SwiftUI

/// Explicit extension groups keep unknown files on the existing document icon.
/// No workspace/file-association icons: those can introduce arbitrary colors.
enum EditorFileKind: String, CaseIterable {
    case document = "doc"
    case text = "doc.plaintext"
    case richText = "doc.richtext"
    case markdown = "text.document"
    case swift = "swift"
    case source = "chevron.left.forwardslash.chevron.right"
    case javascript = "curlybraces.square"
    case stylesheet = "number"
    case shell = "terminal"
    case json = "curlybraces"
    case configuration = "slider.horizontal.3"
    case table = "tablecells"
    case database = "cylinder"
    case log = "list.bullet.rectangle"
    case patch = "plus.forwardslash.minus"
    case certificate = "lock.doc"

    static func resolve(_ url: URL) -> Self {
        switch url.pathExtension.lowercased() {
        case "txt", "text": .text
        case "rtf", "rtfd": .richText
        case "md", "markdown", "mdown", "rst": .markdown
        case "swift": .swift
        case "js", "mjs", "cjs", "jsx", "ts", "mts", "cts", "tsx": .javascript
        case "css", "scss", "sass", "less": .stylesheet
        case "sh", "bash", "zsh", "fish", "ksh", "ps1", "bat", "cmd": .shell
        case "json", "jsonc", "json5": .json
        case "yaml", "yml", "toml", "ini", "conf", "config", "cfg", "properties", "env": .configuration
        case "csv", "tsv": .table
        case "sql": .database
        case "log": .log
        case "diff", "patch": .patch
        case "pem", "crt", "cer", "key", "pub": .certificate
        case "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm", "py", "pyw", "rb", "go", "rs", "java", "kt", "kts", "cs", "fs", "fsx", "php", "pl", "pm", "lua", "r", "dart", "ex", "exs", "erl", "hrl", "hs", "scala", "sc", "html", "htm", "xml", "xhtml", "svg", "vue", "svelte": .source
        default: .document
        }
    }
}

struct EditorFileIcon: View {
    let url: URL
    var body: some View {
        Image(systemName: EditorFileKind.resolve(url).rawValue)
            .resizable().scaledToFit()
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.primary)
            .accessibilityHidden(true)
    }
}
