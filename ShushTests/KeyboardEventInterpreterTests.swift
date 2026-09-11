import XCTest
@testable import Shush

final class KeyboardEventInterpreterTests: XCTestCase {
    func testRecognizesF5() {
        XCTAssertTrue(KeyboardEventInterpreter.isShortcutKey(keyCode: 96))
        XCTAssertTrue(KeyboardEventInterpreter.isShortcutKey(keyCode: 176))
        XCTAssertFalse(KeyboardEventInterpreter.isShortcutKey(keyCode: 97))
    }

    func testRecognizesDictationSystemKey() {
        let keyDown = Int64(0xCF0A00)
        XCTAssertTrue(KeyboardEventInterpreter.isLegacyDictationKey(data1: keyDown))
        XCTAssertEqual(KeyboardEventInterpreter.systemKeyCode(data1: keyDown), 0xCF)
        XCTAssertEqual(KeyboardEventInterpreter.systemKeyState(data1: keyDown), 0xA)
        XCTAssertTrue(KeyboardEventInterpreter.isSystemKeyDown(data1: keyDown))
        XCTAssertFalse(KeyboardEventInterpreter.isSystemKeyUp(data1: keyDown))
    }

    func testDistinguishesDictationRepeatAndKeyUp() {
        XCTAssertFalse(KeyboardEventInterpreter.isSystemKeyDown(data1: Int64(0xCF0A01)))
        XCTAssertFalse(KeyboardEventInterpreter.isSystemKeyDown(data1: Int64(0xCF0B00)))
        XCTAssertTrue(KeyboardEventInterpreter.isSystemKeyUp(data1: Int64(0xCF0B00)))
    }
}
