import XCTest
@testable import Dictate_Anywhere

final class InputSourceMonitorTests: XCTestCase {
    func testLanguageDerivationUsesPrimarySubtagAndHandlesUnsupportedSources() {
        let fixtures: [([String], SupportedLanguage?)] = [
            (["zh-Hans"], .chinese), (["en-US"], .english), (["de"], .german),
            (["nb"], .norwegian), (["ko"], nil), ([], nil),
        ]
        for (tags, expected) in fixtures {
            XCTAssertEqual(InputSourceMonitor.deriveLanguage(fromBCP47: tags), expected, tags.joined(separator: ","))
        }
    }

    @MainActor
    func testAvailableInputSourcesIncludesCurrent() {
        let monitor = InputSourceMonitor()
        guard let current = monitor.currentInputSourceID() else {
            return XCTFail("No current input source")
        }
        let sources = monitor.availableInputSources()
        XCTAssertFalse(sources.isEmpty)
        XCTAssertTrue(sources.contains { $0.id == current })
        XCTAssertTrue(sources.allSatisfy { !$0.localizedName.isEmpty })
    }
}
