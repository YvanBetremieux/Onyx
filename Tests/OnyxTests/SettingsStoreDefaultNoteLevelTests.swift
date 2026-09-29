import XCTest
import RecorderCore
@testable import Onyx

/// `.live` is the user's own hand-written notes and is never a generation
/// target: any persisted "live" must be filtered *at the source*, so that no
/// present or future consumer has to guard against it. Also covers the
/// migration from the single-level era (`defaultNoteLevel`) to the multi-level
/// setting (`defaultNoteLevels`).
final class SettingsStoreDefaultNoteLevelTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.onyx.tests.settings.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Multi-level key

    func test_levelsRoundTrip() {
        defaults.set(["brief", "detaillee"], forKey: "defaultNoteLevels")
        XCTAssertEqual(SettingsStore(defaults: defaults).defaultNoteLevels,
                       [.brief, .detaillee])
    }

    func test_liveAndGarbageAreFilteredOut() {
        defaults.set(["live", "brief", "nonsense"], forKey: "defaultNoteLevels")
        XCTAssertEqual(SettingsStore(defaults: defaults).defaultNoteLevels, [.brief],
                       "a persisted \"live\" or unknown value must never surface")
    }

    func test_emptySelectionIsALegitimateState() {
        defaults.set([String](), forKey: "defaultNoteLevels")
        XCTAssertEqual(SettingsStore(defaults: defaults).defaultNoteLevels, [],
                       "unchecking everything means \"auto-generate nothing\", not a fallback")
    }

    func test_savingPersistsRawValues() {
        let store = SettingsStore(defaults: defaults)
        store.defaultNoteLevels = [.brief, .synthese, .detaillee]
        XCTAssertEqual(defaults.array(forKey: "defaultNoteLevels") as? [String],
                       ["brief", "synthese", "detaillee"])
    }

    // MARK: - Migration from the single-level era

    func test_missingKey_migratesOldSingleLevel() {
        defaults.set("brief", forKey: "defaultNoteLevel")
        XCTAssertEqual(SettingsStore(defaults: defaults).defaultNoteLevels, [.brief])
    }

    func test_missingKey_oldLiveOrGarbage_fallsBackToSynthese() {
        for raw in ["live", "nonsense", "LIVE"] {
            defaults.removeObject(forKey: "defaultNoteLevels")
            defaults.set(raw, forKey: "defaultNoteLevel")
            XCTAssertEqual(SettingsStore(defaults: defaults).defaultNoteLevels, [.synthese],
                           "raw \"\(raw)\" must migrate to the safe default")
        }
    }

    func test_noKeysAtAll_defaultsToSynthese() {
        XCTAssertEqual(SettingsStore(defaults: defaults).defaultNoteLevels, [.synthese])
    }

    /// Whatever comes back, every level must be one the pipeline can actually
    /// generate — the invariant every consumer (pipeline, checkboxes) relies on.
    func test_loadedLevelsAreAlwaysGeneratable() {
        defaults.set(["live", "brief", "synthese", "detaillee", ""], forKey: "defaultNoteLevels")
        for level in SettingsStore(defaults: defaults).defaultNoteLevels {
            XCTAssertTrue(NoteLevel.generatable.contains(level))
        }
    }
}
