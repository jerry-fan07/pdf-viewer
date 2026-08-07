import SwiftUI

/// Colours a fenced code block.
///
/// A hand-rolled lexer rather than a dependency: the app takes exactly one SPM package
/// (SwiftMath, see PLAN.md §1), and what a chat panel needs is the four categories that
/// carry almost all of the legibility — comment, string, number, keyword — not a faithful
/// parse. An unknown language degrades to comments/strings/numbers, which is still a large
/// improvement over one flat colour, and a wrong guess is never worse than plain text.
@MainActor
enum CodeHighlighter {

    private struct Key: Hashable {
        let code: String
        let language: String?
        let dark: Bool
    }

    private static var cache: [Key: AttributedString] = [:]

    /// Streaming re-renders the whole answer on every delta, so a growing code block is
    /// re-lexed dozens of times — the same reason `MathRenderer` caches.
    static func highlight(_ code: String, language: String?, colorScheme: ColorScheme) -> AttributedString {
        let key = Key(code: code, language: language, dark: colorScheme == .dark)
        if let hit = cache[key] { return hit }

        let result = lex(code, grammar: Grammar.named(language), palette: Palette(dark: key.dark))
        if cache.count > 128 { cache.removeAll() }
        cache[key] = result
        return result
    }

    // MARK: - Lexing

    private enum Token {
        case comment, string, number, keyword, type, function
    }

    private static func lex(_ code: String, grammar: Grammar, palette: Palette) -> AttributedString {
        let chars = Array(code)
        var spans: [(range: Range<Int>, token: Token)] = []
        var i = 0

        // Pre-split once: `matches` runs at nearly every character, and rebuilding these
        // arrays inside the loop dominated the lex on a long block.
        let lineComments = grammar.lineComments.map(Array.init)
        let blockOpen = grammar.blockComment.map { Array($0.0) }
        let blockClose = grammar.blockComment.map { Array($0.1) }
        let tripleDouble = Array("\"\"\"")
        let tripleSingle = Array("'''")

        func matches(_ needle: [Character], at index: Int) -> Bool {
            guard index + needle.count <= chars.count else { return false }
            return !needle.indices.contains { chars[index + $0] != needle[$0] }
        }

        func end(of needle: [Character], from index: Int) -> Int {
            var j = index
            while j < chars.count {
                if matches(needle, at: j) { return j + needle.count }
                j += 1
            }
            return chars.count                       // unterminated: colour to the end
        }

        while i < chars.count {
            let c = chars[i]

            if let open = blockOpen, let close = blockClose, matches(open, at: i) {
                let stop = end(of: close, from: i + open.count)
                spans.append((i..<stop, .comment))
                i = stop
                continue
            }
            if let opener = lineComments.first(where: { matches($0, at: i) }) {
                var stop = i + opener.count
                while stop < chars.count, chars[stop] != "\n" { stop += 1 }
                spans.append((i..<stop, .comment))
                i = stop
                continue
            }
            if grammar.tripleQuotedStrings, matches(tripleDouble, at: i) || matches(tripleSingle, at: i) {
                let quote = Array(repeating: c, count: 3)
                let stop = end(of: quote, from: i + 3)
                spans.append((i..<stop, .string))
                i = stop
                continue
            }
            if grammar.stringDelimiters.contains(c) {
                let stop = stringEnd(chars, from: i)
                spans.append((i..<stop, .string))
                i = stop
                continue
            }
            if grammar.backslashCommands, c == "\\", i + 1 < chars.count, chars[i + 1].isLetter {
                var j = i + 1
                while j < chars.count, chars[j].isLetter { j += 1 }
                spans.append((i..<j, .keyword))
                i = j
                continue
            }
            if c.isNumber, i == 0 || !isIdentifier(chars[i - 1]) {
                let stop = numberEnd(chars, from: i)
                spans.append((i..<stop, .number))
                i = stop
                continue
            }
            if isIdentifierStart(c) || (c == "@" && i + 1 < chars.count && isIdentifierStart(chars[i + 1]))
                || (c == "#" && grammar.hashDirectives && i + 1 < chars.count && chars[i + 1].isLetter) {
                var j = c.isLetter || c == "_" ? i : i + 1
                while j < chars.count, isIdentifier(chars[j]) { j += 1 }
                let word = String(chars[i..<j])

                if c == "@" || c == "#" {
                    spans.append((i..<j, .keyword))
                } else if grammar.keywords.contains(word) {
                    spans.append((i..<j, .keyword))
                } else if grammar.builtins.contains(word) {
                    spans.append((i..<j, .type))
                } else if word.first?.isUppercase == true {
                    // Not a parse, a convention: nearly every language in this list names
                    // types in UpperCamelCase, and the ones that don't lose nothing but colour.
                    spans.append((i..<j, .type))
                } else if nextVisible(chars, from: j) == "(" {
                    spans.append((i..<j, .function))
                }
                i = j
                continue
            }
            i += 1
        }

        var out = AttributedString()
        var cursor = 0
        for span in spans {
            if span.range.lowerBound > cursor {
                out.append(plain(String(chars[cursor..<span.range.lowerBound]), palette))
            }
            var piece = AttributedString(String(chars[span.range]))
            piece.foregroundColor = palette.color(span.token)
            out.append(piece)
            cursor = span.range.upperBound
        }
        if cursor < chars.count {
            out.append(plain(String(chars[cursor...]), palette))
        }
        return out
    }

    private static func plain(_ text: String, _ palette: Palette) -> AttributedString {
        var piece = AttributedString(text)
        piece.foregroundColor = palette.plain
        return piece
    }

    private static func stringEnd(_ chars: [Character], from start: Int) -> Int {
        let quote = chars[start]
        var j = start + 1
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == quote { return min(j + 1, chars.count) }
            // An unterminated quote is far more often an apostrophe ("don't") than a string
            // running off the end, so stop it at the line.
            if chars[j] == "\n" { return j }
            j += 1
        }
        return chars.count
    }

    private static func numberEnd(_ chars: [Character], from start: Int) -> Int {
        var j = start
        while j < chars.count {
            let c = chars[j]
            if c.isHexDigit || c == "_" { j += 1; continue }
            if c == ".", j + 1 < chars.count, chars[j + 1].isNumber { j += 1; continue }
            if "xXoO".contains(c), j > start { j += 1; continue }
            if "eEpP".contains(c), j + 1 < chars.count, chars[j + 1] == "+" || chars[j + 1] == "-" { j += 2; continue }
            break
        }
        return j
    }

    private static func isIdentifierStart(_ c: Character) -> Bool { c.isLetter || c == "_" }
    private static func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    private static func nextVisible(_ chars: [Character], from index: Int) -> Character? {
        var j = index
        while j < chars.count, chars[j] == " " { j += 1 }
        return j < chars.count ? chars[j] : nil
    }

    // MARK: - Palette

    /// Xcode's Default and Default (Dark) themes — the colours a macOS user already reads
    /// code in, and both are contrast-checked against the panel's background by Apple.
    private struct Palette {
        let dark: Bool

        var plain: Color { dark ? Color(hex: 0xFFFFFF) : Color(hex: 0x000000) }

        func color(_ token: Token) -> Color {
            switch token {
            case .comment:  return dark ? Color(hex: 0x7F8C98) : Color(hex: 0x5D6C79)
            case .string:   return dark ? Color(hex: 0xFF8170) : Color(hex: 0xC41A16)
            case .number:   return dark ? Color(hex: 0xD9C97C) : Color(hex: 0x1C00CF)
            case .keyword:  return dark ? Color(hex: 0xFF7AB2) : Color(hex: 0x9B2393)
            case .type:     return dark ? Color(hex: 0xDABAFF) : Color(hex: 0x0B4F79)
            case .function: return dark ? Color(hex: 0x78C2B3) : Color(hex: 0x326D74)
            }
        }
    }

    // MARK: - Grammars

    private struct Grammar {
        var keywords: Set<String> = []
        var builtins: Set<String> = []
        var lineComments: [String] = []
        var blockComment: (String, String)?
        var stringDelimiters: [Character] = ["\"", "'"]
        var tripleQuotedStrings = false
        var hashDirectives = false
        var backslashCommands = false

        static func named(_ language: String?) -> Grammar {
            guard let language else { return generic }
            return table[canonical(language)] ?? generic
        }

        /// Fence info strings are whatever the model felt like typing.
        private static func canonical(_ language: String) -> String {
            switch language.lowercased() {
            case "js", "jsx", "node", "mjs": return "javascript"
            case "ts", "tsx": return "typescript"
            case "py", "python3", "ipython": return "python"
            case "sh", "zsh", "bash", "shell", "console", "terminal": return "shell"
            case "c++", "cc", "hpp", "cxx": return "cpp"
            case "h", "objc": return "c"
            case "rs": return "rust"
            case "rb": return "ruby"
            case "golang": return "go"
            case "kt": return "kotlin"
            case "yml": return "yaml"
            case "tex", "latex": return "latex"
            case "postgres", "postgresql", "mysql", "sqlite": return "sql"
            case "m", "octave": return "matlab"
            case "hs": return "haskell"
            case "jl": return "julia"
            default: return language.lowercased()
            }
        }

        /// No keywords — just the lexical categories every language shares. What an unknown
        /// fence gets, and what plain text gets.
        static let generic = Grammar(
            lineComments: ["//", "#"], blockComment: ("/*", "*/")
        )

        private static let cFamilyComments: [String] = ["//"]

        static let table: [String: Grammar] = [
            "swift": Grammar(
                keywords: ["associatedtype", "async", "await", "case", "catch", "class", "continue", "default",
                           "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "false", "final",
                           "for", "func", "guard", "if", "import", "in", "init", "inout", "internal", "is", "let",
                           "lazy", "mutating", "nil", "nonisolated", "open", "operator", "private", "protocol",
                           "public", "repeat", "return", "self", "some", "static", "struct", "subscript", "super",
                           "switch", "throw", "throws", "true", "try", "typealias", "var", "weak", "where", "while"],
                builtins: ["Array", "Bool", "Character", "Dictionary", "Double", "Error", "Int", "Optional",
                           "Result", "Set", "String", "Task", "Void"],
                lineComments: cFamilyComments, blockComment: ("/*", "*/"), stringDelimiters: ["\""],
                tripleQuotedStrings: true, hashDirectives: true
            ),
            "python": Grammar(
                keywords: ["and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
                           "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
                           "in", "is", "lambda", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True",
                           "try", "while", "with", "yield"],
                builtins: ["abs", "bool", "dict", "enumerate", "float", "int", "len", "list", "print", "range",
                           "self", "set", "str", "sum", "super", "tuple", "type", "zip"],
                lineComments: ["#"], tripleQuotedStrings: true
            ),
            "javascript": Grammar(
                keywords: ["async", "await", "break", "case", "catch", "class", "const", "continue", "default",
                           "delete", "do", "else", "export", "extends", "false", "finally", "for", "from",
                           "function", "if", "import", "in", "instanceof", "let", "new", "null", "of", "return",
                           "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined",
                           "var", "void", "while", "yield"],
                builtins: ["Array", "Boolean", "JSON", "Map", "Math", "Number", "Object", "Promise", "Set",
                           "String", "Symbol", "console", "document", "window"],
                lineComments: cFamilyComments, blockComment: ("/*", "*/"),
                stringDelimiters: ["\"", "'", "`"]
            ),
            "go": Grammar(
                keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
                           "for", "func", "go", "goto", "if", "import", "interface", "map", "nil", "package",
                           "range", "return", "select", "struct", "switch", "type", "var", "true", "false"],
                builtins: ["append", "bool", "byte", "cap", "make", "error", "float64", "int", "int64", "len",
                           "new", "panic", "rune", "string", "uint"],
                lineComments: cFamilyComments, blockComment: ("/*", "*/"),
                stringDelimiters: ["\"", "`"]
            ),
            "rust": Grammar(
                keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
                           "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
                           "move", "mut", "pub", "ref", "return", "self", "static", "struct", "super", "trait",
                           "true", "type", "unsafe", "use", "where", "while"],
                builtins: ["Box", "Err", "None", "Ok", "Option", "Result", "Some", "String", "Vec", "bool",
                           "f64", "i32", "i64", "str", "u32", "u64", "usize"],
                lineComments: cFamilyComments, blockComment: ("/*", "*/")
            ),
            "c": Grammar(
                keywords: ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else",
                           "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register",
                           "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union",
                           "unsigned", "void", "volatile", "while"],
                builtins: ["NULL", "bool", "false", "size_t", "true", "uint8_t", "uint32_t", "uint64_t"],
                lineComments: cFamilyComments, blockComment: ("/*", "*/"), hashDirectives: true
            ),
            "cpp": Grammar(
                keywords: ["auto", "bool", "break", "case", "catch", "class", "const", "constexpr", "continue",
                           "decltype", "default", "delete", "do", "double", "else", "enum", "explicit", "extern",
                           "false", "float", "for", "friend", "if", "inline", "int", "long", "namespace", "new",
                           "nullptr", "operator", "private", "protected", "public", "return", "short", "sizeof",
                           "static", "struct", "switch", "template", "this", "throw", "true", "try", "typedef",
                           "typename", "union", "unsigned", "using", "virtual", "void", "while"],
                builtins: ["size_t", "std", "string", "vector"],
                lineComments: cFamilyComments, blockComment: ("/*", "*/"), hashDirectives: true
            ),
            "java": Grammar(
                keywords: ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class",
                           "const", "continue", "default", "do", "double", "else", "enum", "extends", "final",
                           "finally", "float", "for", "if", "implements", "import", "instanceof", "int",
                           "interface", "long", "native", "new", "null", "package", "private", "protected",
                           "public", "return", "short", "static", "super", "switch", "synchronized", "this",
                           "throw", "throws", "transient", "true", "false", "try", "void", "volatile", "while"],
                builtins: ["Integer", "List", "Map", "Object", "String", "System"],
                lineComments: cFamilyComments, blockComment: ("/*", "*/"), stringDelimiters: ["\"", "'"]
            ),
            "kotlin": Grammar(
                keywords: ["as", "break", "by", "class", "continue", "do", "else", "false", "for", "fun", "if",
                           "import", "in", "interface", "internal", "is", "null", "object", "override", "package",
                           "private", "return", "sealed", "super", "suspend", "this", "throw", "true", "try",
                           "val", "var", "when", "while"],
                builtins: ["Any", "Boolean", "Double", "Int", "List", "Map", "String", "Unit"],
                lineComments: cFamilyComments, blockComment: ("/*", "*/")
            ),
            "ruby": Grammar(
                keywords: ["alias", "and", "begin", "break", "case", "class", "def", "do", "else", "elsif", "end",
                           "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "raise",
                           "require", "rescue", "return", "self", "super", "then", "true", "unless", "until",
                           "when", "while", "yield"],
                lineComments: ["#"], blockComment: ("=begin", "=end")
            ),
            "shell": Grammar(
                keywords: ["case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if",
                           "in", "local", "return", "select", "set", "then", "until", "while"],
                builtins: ["awk", "cat", "cd", "curl", "echo", "git", "grep", "ls", "mkdir", "printf", "rm",
                           "sed", "source", "sudo"],
                lineComments: ["#"]
            ),
            "sql": Grammar(
                keywords: ["ALTER", "AND", "AS", "ASC", "BY", "CREATE", "DELETE", "DESC", "DISTINCT", "DROP",
                           "FROM", "GROUP", "HAVING", "IN", "INDEX", "INNER", "INSERT", "INTO", "JOIN", "LEFT",
                           "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "OUTER", "SELECT", "SET", "TABLE",
                           "UNION", "UPDATE", "VALUES", "WHERE", "WITH",
                           "alter", "and", "as", "asc", "by", "create", "delete", "desc", "distinct", "drop",
                           "from", "group", "having", "in", "index", "inner", "insert", "into", "join", "left",
                           "limit", "not", "null", "on", "or", "order", "outer", "select", "set", "table",
                           "union", "update", "values", "where", "with"],
                lineComments: ["--"], blockComment: ("/*", "*/"), stringDelimiters: ["'", "\""]
            ),
            "json": Grammar(
                keywords: ["true", "false", "null"], stringDelimiters: ["\""]
            ),
            "yaml": Grammar(
                keywords: ["true", "false", "null", "yes", "no"], lineComments: ["#"]
            ),
            "haskell": Grammar(
                keywords: ["case", "class", "data", "deriving", "do", "else", "if", "import", "in", "instance",
                           "let", "module", "newtype", "of", "then", "type", "where"],
                lineComments: ["--"], blockComment: ("{-", "-}"), stringDelimiters: ["\""]
            ),
            "julia": Grammar(
                keywords: ["abstract", "begin", "break", "const", "continue", "do", "else", "elseif", "end",
                           "export", "false", "for", "function", "if", "import", "in", "let", "local", "module",
                           "mutable", "return", "struct", "true", "try", "using", "while"],
                lineComments: ["#"], blockComment: ("#=", "=#"), stringDelimiters: ["\""]
            ),
            "matlab": Grammar(
                keywords: ["break", "case", "catch", "continue", "else", "elseif", "end", "for", "function",
                           "global", "if", "otherwise", "persistent", "return", "switch", "try", "while"],
                lineComments: ["%"], stringDelimiters: ["'", "\""]
            ),
            "r": Grammar(
                keywords: ["break", "else", "for", "function", "if", "in", "next", "repeat", "return", "while",
                           "TRUE", "FALSE", "NULL", "NA", "Inf"],
                lineComments: ["#"]
            ),
            "latex": Grammar(
                lineComments: ["%"], stringDelimiters: [], backslashCommands: true
            ),
        ]
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
