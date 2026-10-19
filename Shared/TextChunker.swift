import Foundation

/// Splits text on grapheme-cluster boundaries so a UIKit/macOS event never breaks an emoji or a
/// combining sequence apart. Each returned chunk is at most `maximumUTF16Units` UTF-16 units.
enum TextChunker {
    static let defaultMaximumUTF16Units = 20

    static func chunks(_ text: String, maximumUTF16Units: Int = defaultMaximumUTF16Units) -> [[UInt16]] {
        guard maximumUTF16Units > 0 else { return [] }
        var result: [[UInt16]] = []
        var current: [UInt16] = []

        func flush() {
            guard !current.isEmpty else { return }
            result.append(current)
            current = []
        }

        for character in text {
            let units = Array(String(character).utf16)
            if units.count > maximumUTF16Units {
                // A single extended grapheme cluster is larger than one event. It has to be split,
                // but still never split a surrogate pair.
                flush()
                var index = 0
                while index < units.count {
                    var end = min(index + maximumUTF16Units, units.count)
                    if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) {
                        end -= 1
                    }
                    if end == index {
                        end = min(index + 1, units.count)
                    }
                    result.append(Array(units[index..<end]))
                    index = end
                }
                continue
            }
            if !current.isEmpty, current.count + units.count > maximumUTF16Units {
                flush()
            }
            current.append(contentsOf: units)
        }
        flush()
        return result
    }

    static func text(from chunks: [[UInt16]]) -> String {
        String(decoding: chunks.flatMap { $0 }, as: UTF16.self)
    }
}
