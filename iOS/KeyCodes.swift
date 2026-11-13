import Foundation

/// US-layout macOS virtual key codes for characters, for Command-C style shortcuts typed on the iOS keyboard.
enum KeyCodes {
    struct Key: Equatable {
        let code: UInt16
        let shift: Bool
    }

    static let shift: UInt16 = 56

    private static let table: [Character: Key] = {
        var t: [Character: Key] = [:]
        let letterCodes: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        for (i, code) in letterCodes.enumerated() {
            let lower = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(i)))
            let upper = Character(UnicodeScalar(UInt8(ascii: "A") + UInt8(i)))
            t[lower] = Key(code: code, shift: false)
            t[upper] = Key(code: code, shift: true)
        }
        // Each key: the plain character, the shifted one, the code.
        let pairs: [(Character, Character, UInt16)] = [
            ("1", "!", 18), ("2", "@", 19), ("3", "#", 20), ("4", "$", 21), ("5", "%", 23),
            ("6", "^", 22), ("7", "&", 26), ("8", "*", 28), ("9", "(", 25), ("0", ")", 29),
            ("`", "~", 50), ("-", "_", 27), ("=", "+", 24), ("[", "{", 33), ("]", "}", 30),
            ("\\", "|", 42), (";", ":", 41), ("'", "\"", 39), (",", "<", 43), (".", ">", 47), ("/", "?", 44),
        ]
        for (plain, shifted, code) in pairs {
            t[plain] = Key(code: code, shift: false)
            t[shifted] = Key(code: code, shift: true)
        }
        t[" "] = Key(code: 49, shift: false)
        t["\t"] = Key(code: 48, shift: false)
        t["\n"] = Key(code: 36, shift: false)
        return t
    }()

    static func key(for character: Character) -> Key? {
        table[character]
    }
}
