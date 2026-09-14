import Foundation

/// Keep code and numeric literals out of the language model's rewrite space.
/// Restoration fails closed if the model loses or duplicates a placeholder.
struct ProtectedTranslationInput {
    let text: String
    private let replacements: [(marker: String, original: String)]

    init(_ original: String) {
        let pattern = [
            #"(?s:```.*?```)"#,
            #"`[^`\n]+`"#,
            #"https?://[^\s<>]*[^\s<>.!?)]"#,
            #"(?:R\$|US\$|\$|€|£|¥)\h*[-+]?\d+(?:[.,]\d+)*"#,
            #"(?<![\p{L}\p{N}_])[-+]?\d+(?:[.,:/-]\d+)*(?:%)?(?![\p{L}\p{N}_])"#,
            #"\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\b"#,
            #"\b[a-z]+(?:[A-Z][a-zA-Z0-9]*)+(?:\(\))?"#,
            #"(?:\.{0,2}/|~/)[^\s<>,;]*[^\s<>,;.!?)]"#,
            #"\b[A-Za-z0-9_-]+\.(?:swift|tsx?|jsx?|json|py|md|ya?ml|sh|toml|env|html|css|sql)\b"#,
            #"<start_of_turn>|<end_of_turn>|<\|[^>]+\|>"#,
        ].joined(separator: "|")
        let expression = try! NSRegularExpression(pattern: pattern)
        var prefix = "__PARROT_LITERAL_"
        while original.contains(prefix) { prefix = "_" + prefix }
        let matches = expression.matches(in: original, range: NSRange(original.startIndex..., in: original))
        var replacements: [(String, String)] = []
        var rendered = original
        for (index, match) in matches.enumerated().reversed() {
            guard let range = Range(match.range, in: original) else { continue }
            let literal = String(original[range])
            let marker = "\(prefix)\(index)__"
            replacements.append((marker, literal))
            if let renderedRange = Range(match.range, in: rendered) {
                rendered.replaceSubrange(renderedRange, with: marker)
            }
        }
        self.text = rendered
        self.replacements = replacements
    }

    func restoring(in translated: String) throws -> String {
        var result = translated
        // Validate before substituting so a literal cannot manufacture a marker.
        for (marker, _) in replacements {
            guard translated.components(separatedBy: marker).count == 2 else {
                throw TranslationError.alteredLiteral
            }
        }
        for (marker, original) in replacements {
            result = result.replacingOccurrences(of: marker, with: original)
        }
        return result
    }
}
