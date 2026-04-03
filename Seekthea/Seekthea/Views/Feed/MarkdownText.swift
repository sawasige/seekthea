import SwiftUI

/// **太字**マークアップをパースしてボールド表示するText
struct MarkdownText: View {
    let text: String
    var font: Font = .body
    var boldFont: Font = .body.bold()
    var boldColor: Color = .primary

    var body: some View {
        buildText()
    }

    private func buildText() -> Text {
        let parts = Self.parse(text)
        guard let first = parts.first else { return Text("") }

        var result = makeText(first)
        for part in parts.dropFirst() {
            result = Text("\(result)\(makeText(part))")
        }
        return result
    }

    private func makeText(_ part: TextPart) -> Text {
        if part.isBold {
            Text(part.text).font(boldFont).foregroundColor(boldColor)
        } else {
            Text(part.text).font(font)
        }
    }

    private struct TextPart {
        let text: String
        let isBold: Bool
    }

    // nonisolated static to avoid re-parsing when only fonts change
    private static func parse(_ input: String) -> [TextPart] {
        guard input.contains("**") else {
            return [TextPart(text: input, isBold: false)]
        }

        var parts: [TextPart] = []
        var remaining = input

        while let boldStart = remaining.range(of: "**") {
            let before = String(remaining[remaining.startIndex..<boldStart.lowerBound])
            if !before.isEmpty {
                parts.append(TextPart(text: before, isBold: false))
            }

            let afterStart = boldStart.upperBound
            let afterText = remaining[afterStart...]
            if let boldEnd = afterText.range(of: "**") {
                let boldContent = String(afterText[afterText.startIndex..<boldEnd.lowerBound])
                parts.append(TextPart(text: boldContent, isBold: true))
                remaining = String(afterText[boldEnd.upperBound...])
            } else {
                parts.append(TextPart(text: String(remaining[boldStart.lowerBound...]), isBold: false))
                remaining = ""
            }
        }

        if !remaining.isEmpty {
            parts.append(TextPart(text: remaining, isBold: false))
        }

        return parts
    }
}
