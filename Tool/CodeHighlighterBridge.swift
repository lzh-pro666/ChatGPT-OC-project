import Foundation
import UIKit
import Highlightr

@objcMembers
public final class CodeHighlighterBridge: NSObject, @unchecked Sendable {
    public nonisolated(unsafe) static let shared = CodeHighlighterBridge()
    private let highlightr: Highlightr?

    private override init() {
        self.highlightr = Highlightr()
        super.init()
        // 默认主题，可按需切换："atom-one-light", "atom-one-dark" 等
        _ = self.highlightr?.setTheme(to: "atom-one-light")
        if let theme = self.highlightr?.theme {
            theme.setCodeFont(UIFont.monospacedSystemFont(ofSize: 14, weight: .regular))
        }
    }

    public func highlight(code: String, language: String?, fontSize: CGFloat) -> NSAttributedString {
        guard !code.isEmpty else { return NSAttributedString(string: "") }
        if let theme = self.highlightr?.theme {
            theme.setCodeFont(UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        }
        // language 为空时让 Highlightr 自动检测或作为 plaintext 处理
        let lang = (language?.isEmpty == false) ? language : nil
        if let result = self.highlightr?.highlight(code, as: lang) {
            return result
        }
        return NSAttributedString(string: code, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: UIColor.label
        ])
    }
}


