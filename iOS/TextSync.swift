import Foundation

/// Turns "the hidden text field now says X" into what to type on the Mac.
/// The field holds the recent text of the current buffer; the Mac already has `sent`.
/// Every change is a common prefix kept, the rest of `sent` deleted, and the rest of the new text typed.
struct TextSync {
    enum Step: Equatable {
        case backspace(Int)
        case text(String)
        case returnKey
    }

    /// Never delete more than this on the Mac for one change: its cursor may have moved since.
    static let maxBackspaces = 40
    /// Past this many characters the field is cut back after a word, so it never grows without end.
    static let trimLength = 300
    static let keepLength = 60

    /// The text the Mac has received from the current buffer.
    private(set) var sent = ""
    /// Set when a change was refused (too much to delete): the caller clears the field and calls `reset()`.
    private(set) var needsReset = false

    mutating func update(to new: String) -> [Step] {
        let old = Array(sent)
        let now = Array(new)
        var prefix = 0
        while prefix < old.count, prefix < now.count, old[prefix] == now[prefix] { prefix += 1 }
        let deletions = old.count - prefix
        if deletions > TextSync.maxBackspaces {
            needsReset = true
            return []
        }
        var steps: [Step] = []
        if deletions > 0 { steps.append(.backspace(deletions)) }

        // Type what is new; a line break is the Return key, and the field keeps only what follows the last one.
        var pending = ""
        var afterReturn: String?
        for ch in now[prefix...] {
            if ch.isNewline {
                if !pending.isEmpty { steps.append(.text(pending)) }
                pending = ""
                steps.append(.returnKey)
                afterReturn = ""
            } else {
                pending.append(ch)
                if afterReturn != nil { afterReturn!.append(ch) }
            }
        }
        if !pending.isEmpty { steps.append(.text(pending)) }
        sent = afterReturn ?? new
        return steps
    }

    /// Forget the buffer: the Mac's cursor or focus may have moved.
    mutating func reset() {
        sent = ""
        needsReset = false
    }

    /// The field matches `text` again without anything being typed (after a trim, or a combo key taken out).
    mutating func adopt(_ text: String) {
        sent = text
    }

    func shouldTrim(_ text: String) -> Bool {
        guard let last = text.last, last == " " else { return false }
        return text.count > TextSync.trimLength
    }

    /// The last `keepLength` characters of `text`, starting at a word boundary.
    static func trimmed(_ text: String) -> String {
        guard text.count > keepLength else { return text }
        let start = text.index(text.endIndex, offsetBy: -keepLength)
        var tail = text[start...]
        if !text[text.index(before: start)].isWhitespace {
            // Mid-word: drop the partial word.
            if let space = tail.firstIndex(where: { $0.isWhitespace }) {
                tail = tail[tail.index(after: space)...]
            } else {
                tail = tail[tail.endIndex...]
            }
        }
        while let first = tail.first, first.isWhitespace, tail.count > 1 { tail = tail.dropFirst() }
        return String(tail)
    }
}
