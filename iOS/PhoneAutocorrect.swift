import UIKit

/// The typing behind the drawn phone keyboard: autocorrect, suggestions, auto-capitals, the double-space
/// period and undoing a correction with backspace. The text is the hidden `TypingProxy`'s buffer, and every
/// change goes to the Mac through `TypingProxy.typed`, exactly as a change from the iOS keyboard would.
final class PhoneTyping {
    private let proxy: TypingProxy
    private weak var view: PhoneKeyboardView?

    private struct Correction {
        let typed: String
        let corrected: String
        let ending: String
        /// The buffer right after it was applied; a backspace undoes it only from here.
        let buffer: String
    }

    /// The last correction, while nothing else has been pressed since.
    private var lastCorrection: Correction?
    /// A word put back as typed: the next word-ending key leaves it alone.
    private var keptAsTyped: String?
    /// What the strip's slots 1 and 2 would put in.
    private var candidates: [String] = []
    /// The buffer right after a suggestion or the literal slot added its space: punctuation next replaces that space.
    private var spaceAddedBuffer: String?
    /// The strip is behind the buffer (held off while delete repeats).
    private var stripStale = false
    private var warmedUp = false

    init(proxy: TypingProxy, view: PhoneKeyboardView) {
        self.proxy = proxy
        self.view = view
        view.onInsert = { [weak self] text in self?.insert(text) }
        view.onDelete = { [weak self] repeating in self?.delete(repeating: repeating) }
        view.onDeleteEnded = { [weak self] in self?.deleteEnded() }
        view.onReturn = { [weak self] in self?.returnKey() }
        view.onSuggestion = { [weak self] index in self?.pick(index) }
        refresh()
    }

    /// The checker's guesses come in a much worse order for the first few seconds after its first use
    /// (helo: hello 7th, then 2nd), so it is asked once when the drawn keyboard first shows.
    static func warmUp() {
        DispatchQueue.main.async { _ = rankedGuesses(for: "helo") }
    }

    /// The drawn keyboard came up: the iOS keyboard may have changed the buffer since it was last up,
    /// and the settings may have changed. The first time, the spelling checker is warmed up.
    func keyboardShown() {
        lastCorrection = nil
        keptAsTyped = nil
        spaceAddedBuffer = nil
        if !warmedUp {
            warmedUp = true
            #if DEBUG
            PhoneTyping.unlearnForTests()
            #endif
            PhoneTyping.warmUp()
        }
        refresh()
    }

    private var buffer: String { proxy.text ?? "" }
    private var latched: Bool { proxy.bar.hasLatches }

    /// The proxy forgot its buffer (a click, a bar key, a reconnect): forget the rest too. Caps lock stays.
    func reset() {
        lastCorrection = nil
        keptAsTyped = nil
        spaceAddedBuffer = nil
        refresh()
    }

    // MARK: Keys

    func insert(_ text: String) {
        lastCorrection = nil
        let old = buffer
        let spaceAdded = spaceAddedBuffer != nil && spaceAddedBuffer == old
        spaceAddedBuffer = nil
        // With a Mac modifier latched every key goes through as it is: Command-C, Command-Space.
        guard !latched, text.count == 1, let ch = text.first else {
            commit(old + text)
            return
        }
        if spaceAdded, PhoneTyping.spaceTakers.contains(ch), old.hasSuffix(" ") {
            // "word ." -> "word. ": the space a suggestion added moves after the punctuation.
            keptAsTyped = nil
            commit(String(old.dropLast()) + text + " ")
            return
        }
        if ch == " ", old.hasSuffix(" "), let before = old.dropLast().last, before.isLetter || before.isNumber {
            // Two spaces after a word: a full stop.
            keptAsTyped = nil
            commit(String(old.dropLast()) + ". ")
            return
        }
        if PhoneTyping.wordEnders.contains(ch) {
            endWord(with: text)
            return
        }
        commit(old + text)
    }

    func returnKey() {
        lastCorrection = nil
        spaceAddedBuffer = nil
        if latched {
            commit(buffer + "\n")
        } else {
            endWord(with: "\n")
        }
    }

    /// `repeating`: a repeat of the held key. Shift follows at once; the strip waits for the key to stop.
    func delete(repeating: Bool = false) {
        spaceAddedBuffer = nil
        if latched {
            // Option-delete, Command-delete: one modified backspace. The Mac may have taken a word or
            // a line, so what the buffer holds is no longer known.
            lastCorrection = nil
            keptAsTyped = nil
            proxy.send?([.key(code: 51, down: true, isRepeat: false), .key(code: 51, down: false, isRepeat: false)])
            Haptics.shared.play(.key)
            proxy.bar.consumeLatches()
            proxy.reset()
            return
        }
        if let last = lastCorrection, buffer == last.buffer {
            // Right after a correction, backspace puts back what was typed (without the ending key),
            // and the word is learned so it is not corrected again.
            lastCorrection = nil
            keptAsTyped = last.typed
            PhoneTyping.learn(last.typed)
            commit(String(buffer.dropLast(last.corrected.count + last.ending.count)) + last.typed, stripNow: !repeating)
            return
        }
        lastCorrection = nil
        let old = buffer
        if old.isEmpty {
            proxy.deleteBackward() // keeps deleting on the Mac past the start of the buffer
            if repeating { stripStale = true; refreshShift() } else { refresh() }
        } else {
            commit(String(old.dropLast()), stripNow: !repeating)
        }
    }

    private func deleteEnded() {
        if stripStale { refresh() }
    }

    /// Slot 0 keeps the word as typed, 1 and 2 put in that word; each adds a space.
    func pick(_ index: Int) {
        // A latched modifier is let go first: a suggestion is text, never a shortcut.
        if latched { proxy.bar.consumeLatches() }
        if stripStale { refresh() } // candidates for the word as it is now
        lastCorrection = nil
        keptAsTyped = nil
        spaceAddedBuffer = nil
        let old = buffer
        let word = PhoneTyping.currentWord(of: old)
        guard !word.isEmpty else { return }
        if index == 0 {
            if PhoneTyping.isMisspelled(word) { PhoneTyping.learn(word) }
            commit(old + " ")
        } else if index - 1 < candidates.count {
            commit(String(old.dropLast(word.count)) + candidates[index - 1] + " ")
        } else {
            return
        }
        spaceAddedBuffer = buffer
    }

    private func endWord(with ending: String) {
        let old = buffer
        let word = PhoneTyping.currentWord(of: old)
        defer { keptAsTyped = nil }
        if let fixed = correction(for: word, in: old, ending: ending) {
            let new = String(old.dropLast(word.count)) + fixed + ending
            commit(new)
            // After a Return the buffer starts again, so there is nothing to put back.
            if ending != "\n", buffer == new {
                lastCorrection = Correction(typed: word, corrected: fixed, ending: ending, buffer: new)
            }
        } else {
            commit(old + ending)
        }
    }

    /// What `ending` (nil: whatever ends the word, for the strip) would turn the last word into, or nil.
    private func correction(for word: String, in text: String, ending: String? = nil) -> String? {
        guard proxy.autocorrect, !latched, !word.isEmpty, word != keptAsTyped else { return nil }
        let head = text.dropLast(word.count)
        // Only a word on its own: not part of @name, src/x, --flag, #tag, a.b or something with digits.
        if let before = head.last, !before.isWhitespace, !PhoneTyping.openers.contains(before) { return nil }
        // A capital typed mid-sentence was meant (a name).
        var lead = head
        while let last = lead.last, PhoneTyping.openers.contains(last) { lead = lead.dropLast() }
        if word.first?.isUppercase == true, !PhoneTyping.startsSentence(lead) { return nil }
        // i.e. stays as typed.
        if word == "i", ending == "." { return nil }
        return PhoneTyping.autoCorrection(for: word)
    }

    private func commit(_ new: String, stripNow: Bool = true) {
        proxy.typed(new)
        if stripNow {
            refresh()
        } else {
            stripStale = true
            refreshShift()
        }
    }

    // MARK: Strip and shift

    func refresh() {
        stripStale = false
        let text = buffer
        let word = PhoneTyping.currentWord(of: text)
        var slots: [PhoneKeyboardView.Suggestion] = []
        candidates = []
        if !word.isEmpty {
            let fix = correction(for: word, in: text)
            var list = PhoneTyping.suggestions(for: word)
            if let fix { list = [fix] + list.filter { $0 != fix } }
            candidates = Array(list.prefix(2))
            slots = [PhoneKeyboardView.Suggestion(text: "\u{201C}\(word)\u{201D}")]
            for (i, candidate) in candidates.enumerated() {
                slots.append(PhoneKeyboardView.Suggestion(text: candidate, isDefault: i == 0 && fix != nil))
            }
        }
        while slots.count < 3 { slots.append(PhoneKeyboardView.Suggestion(text: "")) }
        view?.suggestions = slots
        refreshShift()
    }

    /// Auto-capitals: at the start, after a sentence and after a line break; never with a Mac modifier latched.
    /// A shift the user tapped and caps lock are left alone.
    func refreshShift() {
        view?.setAutoShift(proxy.autoCapitalize && !latched && PhoneTyping.startsSentence(buffer))
    }

    // MARK: Words (pure)

    static let wordEnders: Set<Character> = [" ", ".", ",", "!", "?", ";", ":"]
    /// Punctuation that takes the place of a space a suggestion added.
    static let spaceTakers: Set<Character> = [".", ",", "!", "?", ";", ":"]
    /// What may come straight before a word autocorrect touches, besides whitespace.
    static let openers: Set<Character> = ["\"", "'", "\u{201C}", "\u{2018}", "\u{00AB}", "(", "[", "{"]

    /// At the start, after a sentence, or after a line break.
    static func startsSentence<S: StringProtocol>(_ text: S) -> Bool {
        text.isEmpty || text.hasSuffix(". ") || text.hasSuffix("? ") || text.hasSuffix("! ") || text.last?.isNewline == true
    }

    /// The user kept `word` as typed (undid its correction, or tapped it in the strip): never correct it again.
    static func learn(_ word: String) {
        UITextChecker.learnWord(word.contains(where: { $0.isUppercase }) ? word : word.lowercased())
    }

    private static func hasLearned(_ word: String) -> Bool {
        UITextChecker.hasLearnedWord(word) || UITextChecker.hasLearnedWord(word.lowercased())
    }

    #if DEBUG
    /// `-unlearnWords a,b`: tests that undo a correction (which learns the word) start from the same place each run.
    static func unlearnForTests() {
        for word in (UserDefaults.standard.string(forKey: "unlearnWords") ?? "").split(separator: ",") {
            UITextChecker.unlearnWord(String(word))
        }
    }
    #endif

    /// The trailing run of letters and apostrophes.
    static func currentWord(of text: String) -> String {
        String(text.reversed().prefix { $0.isLetter || $0 == "'" }.reversed())
    }

    private static let checker = UITextChecker()

    static let language: String = {
        let available = UITextChecker.availableLanguages
        if available.contains("en_US") { return "en_US" }
        return available.first { $0.hasPrefix("en") } ?? "en"
    }()

    /// Contractions typed without the apostrophe (and "alot"). Some are words of their own (cant, wont)
    /// that the spelling checker accepts, but iOS fixes them all, and almost nobody means the bare form.
    private static let contractions: [String: String] = [
        "alot": "a lot",
        "im": "I'm", "ive": "I've", "dont": "don't", "cant": "can't", "wont": "won't", "didnt": "didn't",
        "doesnt": "doesn't", "isnt": "isn't", "arent": "aren't", "wasnt": "wasn't", "werent": "weren't",
        "hasnt": "hasn't", "havent": "haven't", "hadnt": "hadn't", "couldnt": "couldn't", "wouldnt": "wouldn't",
        "shouldnt": "shouldn't", "youre": "you're", "youve": "you've", "youll": "you'll", "theyre": "they're",
        "theyve": "they've", "thats": "that's", "whats": "what's", "theres": "there's", "heres": "here's",
        "shes": "she's", "weve": "we've", "aint": "ain't", "itll": "it'll", "thatll": "that'll",
    ]

    static func isMisspelled(_ word: String) -> Bool {
        let range = NSRange(location: 0, length: (word as NSString).length)
        let found = checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: language)
        return found.location != NSNotFound
    }

    /// What a word-ending key turns `word` into, or nil to leave it.
    static func autoCorrection(for word: String) -> String? {
        guard !word.isEmpty, !hasLearned(word) else { return nil }
        if word == "i" { return "I" }
        let letters = word.filter { $0.isLetter }
        guard letters.count >= 2, !word.contains(where: { $0.isNumber }),
              !word.dropFirst().contains(where: { $0.isUppercase }) else { return nil }
        // No vowel: npm, gg, brb.
        guard letters.lowercased().contains(where: { "aeiouy".contains($0) }) else { return nil }
        if let fixed = contractions[word.lowercased()] { return matchCase(fixed, to: word) }
        guard isMisspelled(word) else { return nil }
        // Never split or hyphenate a word by itself (well bytes, sports-book).
        guard let best = rankedGuesses(for: word).first(where: { !$0.word.contains(" ") && !$0.word.contains("-") }) else { return nil }
        let limit = letters.count <= 3 ? 0.7 : letters.count <= 6 ? 1.0 : 1.5
        guard best.cost <= limit + 1e-9 else { return nil }
        return matchCase(best.word, to: word)
    }

    /// Corrections for a misspelled word, completions for one spelled right so far; best first.
    static func suggestions(for word: String) -> [String] {
        var list: [String] = []
        if let fixed = contractions[word.lowercased()] { list.append(fixed) }
        if isMisspelled(word) {
            list += rankedGuesses(for: word).map(\.word)
        } else {
            let range = NSRange(location: 0, length: (word as NSString).length)
            list += (checker.completions(forPartialWordRange: range, in: word, language: language) ?? [])
                .filter { $0.lowercased() != word.lowercased() }
        }
        var seen = Set<String>()
        return list.map { matchCase($0, to: word) }.filter { seen.insert($0).inserted }
    }

    /// The checker's guesses, ranked for typing: closest on the keyboard first, its own order breaking ties.
    static func rankedGuesses(for word: String) -> [(word: String, cost: Double)] {
        let range = NSRange(location: 0, length: (word as NSString).length)
        let guesses = checker.guesses(forWordRange: range, in: word, language: language) ?? []
        let typed = Array(word.lowercased())
        return guesses.enumerated()
            .map { index, guess in (guess, typingCost(typed, Array(guess.lowercased())) + 0.15 * Double(index), index) }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }
            .map { (word: $0.0, cost: $0.1) }
    }

    /// Keeps a capital the user typed at the start; the guess's own capitals (I'm, names) stay.
    static func matchCase(_ guess: String, to typed: String) -> String {
        guard let first = typed.first, first.isUppercase else { return guess }
        return guess.prefix(1).uppercased() + guess.dropFirst()
    }

    // MARK: Typing distance

    /// iPhone key centres in key widths: the second row half a key in, the third a key and a half.
    private static let keyPositions: [Character: (x: Double, y: Double)] = {
        var p: [Character: (Double, Double)] = [:]
        for (row, (letters, inset)) in [("qwertyuiop", 0.0), ("asdfghjkl", 0.5), ("zxcvbnm", 1.5)].enumerated() {
            for (i, c) in letters.enumerated() { p[c] = (inset + Double(i), Double(row)) }
        }
        return p
    }()

    /// Neighbours on the same row, or touching on the row above or below.
    static func adjacent(_ a: Character, _ b: Character) -> Bool {
        guard let p = keyPositions[a], let q = keyPositions[b], a != b else { return false }
        let dx = abs(p.x - q.x), dy = abs(p.y - q.y)
        return (dy == 0 && dx == 1) || (dy == 1 && dx <= 0.5)
    }

    /// Edit distance from what was typed to a guess, weighted for thumbs on glass.
    static func typingCost(_ typed: [Character], _ guess: [Character]) -> Double {
        let n = typed.count, m = guess.count
        if n == 0 { return Double(m) }
        if m == 0 { return Double(n) }
        var d = Array(repeating: Array(repeating: 0.0, count: m + 1), count: n + 1)
        func insertCost(_ j: Int) -> Double { // guess[j - 1] is missing from what was typed
            let c = guess[j - 1]
            if c == "'" { return 0.2 }
            if (j >= 2 && guess[j - 2] == c) || (j < m && guess[j] == c) { return 0.4 } // a missed double letter
            if c == "h", j >= 2, "cstwgp".contains(guess[j - 2]) { return 0.5 } // the h of ch, sh, th, wh, gh, ph
            return 1.0
        }
        func deleteCost(_ i: Int) -> Double { // typed[i - 1] is not in the guess
            let c = typed[i - 1]
            if (i >= 2 && typed[i - 2] == c) || (i < n && typed[i] == c) { return 1.0 } // a doubled letter (untill)
            return 1.2 // a letter typed on purpose, more often than not (zorvex, kaydrin)
        }
        for i in 1...n { d[i][0] = d[i - 1][0] + deleteCost(i) }
        for j in 1...m { d[0][j] = d[0][j - 1] + insertCost(j) }
        for i in 1...n {
            for j in 1...m {
                let a = typed[i - 1], b = guess[j - 1]
                let substitution = a == b ? 0 : adjacent(a, b) ? 0.6 : 1.0
                var best = min(d[i - 1][j - 1] + substitution, d[i - 1][j] + deleteCost(i), d[i][j - 1] + insertCost(j))
                if i > 1, j > 1, a == guess[j - 2], typed[i - 2] == b, a != b {
                    best = min(best, d[i - 2][j - 2] + 0.7)
                }
                d[i][j] = best
            }
        }
        return d[n][m]
    }

    #if DEBUG
    static let tableTypos = ["helo", "wrold", "teh", "adn", "thier", "recieve", "becuase", "definately", "tommorow",
                             "seperate", "im", "dont", "cant", "wont", "youre", "thats", "i", "hapy", "freind", "wich",
                             "taht", "waht", "jsut", "knwo", "liek", "thnaks", "plese", "tomorow", "yuo", "nad", "hte",
                             "amd", "wirk", "tjis", "goung", "becasue", "untill", "realy", "beleive", "acheive",
                             "occured", "wierd", "probaly", "somthing", "alot"]
    static let tableCorrect = ["hello", "world", "the", "tomorrow", "receive", "help", "held", "hero", "on", "of",
                               "and", "that", "what", "just", "know", "like", "thanks", "please", "you", "going",
                               "work", "this", "is", "it", "a", "an", "in", "to", "we", "me",
                               // Names and code-like words the checker does not know: left as typed.
                               "zorvex", "kaydrin", "tmux", "npm", "gg", "bytewell", "codepath"]

    /// `-autocorrectTable YES`: what a following space would leave for each word, in Documents/autocorrect.txt.
    /// The checker is warmed up as the drawn keyboard would do it, and the table written 5 s later,
    /// when typing would really start.
    static func writeTable() {
        unlearnForTests()
        warmUp()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { writeTableNow() }
    }

    private static func writeTableNow() {
        let lines = (tableTypos + tableCorrect).map { "\($0) -> \(autoCorrection(for: $0) ?? $0)" }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("autocorrect.txt")
        try? (["# language \(language)"] + lines).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        // The ranked guesses behind each typo (and each word that must stay), for tuning the costs.
        let guesses = (tableTypos + tableCorrect.suffix(7)).map { typo in
            "\(typo) [\(autoCorrection(for: typo) ?? "-")]: " + rankedGuesses(for: typo).prefix(5).map { "\($0.word) \(String(format: "%.2f", $0.cost))" }.joined(separator: ", ")
        }
        try? guesses.joined(separator: "\n").appending("\n")
            .write(to: url.deletingLastPathComponent().appendingPathComponent("autocorrect-guesses.txt"), atomically: true, encoding: .utf8)
    }
    #endif
}
