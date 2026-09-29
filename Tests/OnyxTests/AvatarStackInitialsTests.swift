import XCTest
@testable import Onyx

final class AvatarStackInitialsTests: XCTestCase {
    func test_twoWordName_takesFirstLetterOfFirstTwoWords() {
        XCTAssertEqual(AvatarStack.initials(for: "Yvan Betremieux"), "YB")
    }

    func test_singleWordName_takesOneLetter() {
        XCTAssertEqual(AvatarStack.initials(for: "yvan"), "Y")
    }

    func test_moreThanTwoWords_keepsOnlyTwoLetters() {
        XCTAssertEqual(AvatarStack.initials(for: "Jean Pierre Marie Dupont"), "JD")
    }

    func test_separatorsOtherThanSpace_areTreatedAsWordBreaks() {
        XCTAssertEqual(AvatarStack.initials(for: "yvan.betremieux"), "YB")
        XCTAssertEqual(AvatarStack.initials(for: "SPEAKER_00"), "S0")
        XCTAssertEqual(AvatarStack.initials(for: "anne-marie"), "AM")
    }

    func test_emptyOrWhitespaceOnly_returnsNil() {
        XCTAssertNil(AvatarStack.initials(for: ""))
        XCTAssertNil(AvatarStack.initials(for: "   \n\t "))
        XCTAssertNil(AvatarStack.initials(for: "._-"))
    }

    func test_emojiName_returnsWholeGraphemeCluster_withoutCrashing() {
        // A single emoji is one grapheme cluster; slicing by Character keeps it
        // intact (slicing by UTF-16 unit would produce a broken surrogate).
        XCTAssertEqual(AvatarStack.initials(for: "👩‍👩‍👧 Famille"), "👩‍👩‍👧F")
    }

    func test_veryLongName_isStillTwoCharacters() {
        let long = String(repeating: "a", count: 5_000) + " " + String(repeating: "b", count: 5_000)
        XCTAssertEqual(AvatarStack.initials(for: long), "AB")
    }

    func test_initialsForNames_dropsUnusableEntriesAndDeduplicatesNothing() {
        XCTAssertEqual(AvatarStack.initials(forNames: ["Yvan Betremieux", "", "Sophie Martin"]),
                       ["YB", "SM"])
        XCTAssertEqual(AvatarStack.initials(forNames: []), [])
    }

    // MARK: - Overflow

    func test_noOverflow_whenCountFitsInMaxVisible() {
        let d = AvatarStack.display(initials: ["YB", "SM", "JD"], maxVisible: 4)
        XCTAssertEqual(d.visible, ["YB", "SM", "JD"])
        XCTAssertNil(d.overflow)
    }

    func test_overflow_reservesTheLastSlotForTheCounter() {
        let d = AvatarStack.display(initials: ["A", "B", "C", "D", "E", "F"], maxVisible: 4)
        XCTAssertEqual(d.visible, ["A", "B", "C"])
        XCTAssertEqual(d.overflow, 3)
    }

    func test_emptyInitials_producesNothing() {
        let d = AvatarStack.display(initials: [], maxVisible: 4)
        XCTAssertTrue(d.visible.isEmpty)
        XCTAssertNil(d.overflow)
    }

    func test_maxVisibleOfOne_showsOnlyTheCounter() {
        let d = AvatarStack.display(initials: ["A", "B", "C"], maxVisible: 1)
        XCTAssertTrue(d.visible.isEmpty)
        XCTAssertEqual(d.overflow, 3)
    }
}
