import XCTest
@testable import RemoteControlCore

final class TextChunkerTests: XCTestCase {
    func testRespectsMaximumAndReconstructs() {
        let samples = ["", "a", String(repeating: "abcdefghij", count: 10),
                       String(repeating: "中文测试", count: 50)]
        for text in samples {
            let chunks = TextChunker.chunks(text)
            XCTAssertTrue(chunks.allSatisfy { $0.count <= TextChunker.defaultMaximumUTF16Units })
            XCTAssertEqual(TextChunker.text(from: chunks), text)
        }
    }

    func testDoesNotSplitGraphemeClusters() {
        let family = "👨‍👩‍👧‍👦"
        let flag = "🇨🇳"
        let combined = "e\u{301}"
        let text = String(repeating: "a", count: 19) + family + flag
            + String(repeating: combined, count: 12) + "z"
        let chunks = TextChunker.chunks(text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= TextChunker.defaultMaximumUTF16Units })
        XCTAssertEqual(TextChunker.text(from: chunks), text)

        let familyUnits = Array(family.utf16)
        XCTAssertTrue(chunks.contains { chunk in
            guard chunk.count >= familyUnits.count else { return false }
            for start in 0...(chunk.count - familyUnits.count) {
                if Array(chunk[start..<start + familyUnits.count]) == familyUnits { return true }
            }
            return false
        })

        for chunk in chunks {
            if let first = chunk.first {
                XCTAssertFalse((UInt16(0x0300)...UInt16(0x036F)).contains(first),
                               "A chunk must not start with a combining mark")
            }
        }
    }

    func testSplitsAnOversizedSingleGraphemeWithoutLosingUnits() {
        let text = "a" + String(repeating: "\u{301}", count: 40)
        let chunks = TextChunker.chunks(text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= TextChunker.defaultMaximumUTF16Units })
        XCTAssertEqual(TextChunker.text(from: chunks), text)
    }

    func testZeroLimitProducesNoChunks() {
        XCTAssertEqual(TextChunker.chunks("abc", maximumUTF16Units: 0), [])
    }
}
