import XCTest
@testable import Shush

final class KeyboardEventInterpreterTests: XCTestCase {
    func testRecognizesF5() {
        XCTAssertTrue(KeyboardEventInterpreter.isF5(keyCode: 96))
        XCTAssertFalse(KeyboardEventInterpreter.isF5(keyCode: 97))
    }

    func testRecognizesDictationSystemKey() {
        let keyDown = Int64(0xCF0A00)
        XCTAssertTrue(KeyboardEventInterpreter.isDictationKey(data1: keyDown))
        XCTAssertTrue(KeyboardEventInterpreter.isSystemKeyDown(data1: keyDown))
        XCTAssertFalse(KeyboardEventInterpreter.isSystemKeyUp(data1: keyDown))
    }

    func testDistinguishesDictationRepeatAndKeyUp() {
        XCTAssertFalse(KeyboardEventInterpreter.isSystemKeyDown(data1: Int64(0xCF0A01)))
        XCTAssertFalse(KeyboardEventInterpreter.isSystemKeyDown(data1: Int64(0xCF0B00)))
        XCTAssertTrue(KeyboardEventInterpreter.isSystemKeyUp(data1: Int64(0xCF0B00)))
    }
}
