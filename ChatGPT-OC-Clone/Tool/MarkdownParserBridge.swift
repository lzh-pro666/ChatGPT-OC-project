import Foundation
import Down

@objcMembers
public final class MarkdownParserBridge: NSObject, @unchecked Sendable {
    public nonisolated(unsafe) static let shared = MarkdownParserBridge()

    public func parseToBlocks(_ raw: String) -> [[String: Any]] {
        guard !raw.isEmpty else { return [] }
        // 使用 Down 的 AST 解析
        let down = Down(markdownString: raw)
        guard let doc = try? down.toDocument() else { return [] }

        var blocks: [[String: Any]] = []
        // 使用 Down 提供的 childSequence 兼容地遍历子节点
        for node in doc.childSequence {
            switch node {
            case let h as Heading:
                let text = condenseWhitespace(h.children.map { Self.extractPlainText(from: $0) }.joined())
                blocks.append(["type": "heading", "level": h.headingLevel, "text": text])
            case let p as Paragraph:
                let text = condenseWhitespace(p.children.map { Self.extractPlainText(from: $0) }.joined())
                if !text.isEmpty { blocks.append(["type": "paragraph", "text": text]) }
            case let cb as CodeBlock:
                let info = cb.fenceInfo?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ?? ""
                let code = cb.literal ?? ""
                blocks.append(["type": "code", "language": info, "code": code])
            case _ as ThematicBreak:
                blocks.append(["type": "hr"])
            case let bq as BlockQuote:
                let text = condenseWhitespace(bq.children.map { Self.extractPlainText(from: $0) }.joined(separator: "\n"))
                if !text.isEmpty { blocks.append(["type": "quote", "text": text]) }
            case let list as List:
                list.children.forEach { item in
                    if let it = item as? Item {
                        let text = condenseWhitespace(it.children.map { Self.extractPlainText(from: $0) }.joined(separator: "\n"))
                        if !text.isEmpty { blocks.append(["type": "listItem", "text": text]) }
                    }
                }
            default:
                break
            }
        }
        return blocks
    }

    // 递归提取行内文本，包含 Text / Code 等节点；其他节点下钻其子节点
    private static func extractPlainText(from node: Node) -> String {
        switch node {
        case let t as Text:
            return t.literal ?? ""
        case let c as Code:
            return c.literal ?? ""
        default:
            return node.children.map { extractPlainText(from: $0) }.joined()
        }
    }

    private func condenseWhitespace(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        let components = trimmed.components(separatedBy: CharacterSet.whitespacesAndNewlines).filter { !$0.isEmpty }
        return components.joined(separator: " ")
    }
}


