import SwiftUI

/// Keep result formatting consistent between the live task box and the saved file.
struct TaskResultText: View {
    let text: String
    var body: Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
