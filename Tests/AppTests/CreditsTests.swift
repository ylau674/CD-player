import AppKit
import XCTest

final class CreditsTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func normalized(_ text: some StringProtocol) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func credits() throws -> NSAttributedString {
        try NSAttributedString(
            url: Self.root.appending(path: "App/Credits.rtf"), options: [:], documentAttributes: nil
        )
    }

    // The BSD licence requires binary distributions to reproduce both notices in full.
    func testCreditsReproduceTheVendoredLibhdcdNoticesInFull() throws {
        let license = try String(
            contentsOf: Self.root.appending(path: "Packages/CDKit/Sources/HDCD/LICENSE"), encoding: .utf8
        )
        let shown = normalized(try credits().string)
        let blocks = [
            ("libhdcd:", "Original HDCD decoder from foo_hdcd:"),
            ("Original HDCD decoder from foo_hdcd:", "Autotools-based build system:"),
        ]
        for (start, end) in blocks {
            let lower = try XCTUnwrap(license.range(of: start)).lowerBound
            let upper = try XCTUnwrap(license.range(of: end, range: lower..<license.endIndex)).lowerBound
            let notice = normalized(license[lower..<upper])
            XCTAssertTrue(notice.contains("Redistribution and use in source and binary forms"))
            XCTAssertTrue(shown.contains(notice), "Credits.rtf must contain the notice starting \(start)")
        }
        XCTAssertTrue(shown.contains("Licensed under the Apache License, Version 2.0."))
    }

    func testCreditsUseTheSystemFontAndAdaptiveTextColour() throws {
        let text = try credits()
        var fonts = Set<String>()
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, _, _ in
            XCTAssertNil(attributes[.foregroundColor], "A fixed colour would be unreadable in one appearance")
            if let font = attributes[.font] as? NSFont { fonts.insert(font.familyName ?? font.fontName) }
        }
        XCTAssertEqual(fonts, [try XCTUnwrap(NSFont.systemFont(ofSize: 11).familyName)])
    }
}
