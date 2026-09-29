import XCTest
@testable import RecorderCore

final class ClaudeBinaryLocatorTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeBinaryLocatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// Crée un fichier sous `home` ; exécutable par défaut.
    @discardableResult
    private func makeFile(_ relative: String, executable: Bool = true,
                          contents: String = "#!/bin/sh\n") throws -> URL {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644],
                                              ofItemAtPath: url.path)
        return url
    }

    /// Pas de chemins système ni de shell réels : le test ne doit dépendre que
    /// du faux home, pas de ce qui est installé sur la machine qui le lance.
    private func locator(shell: String? = nil) -> ClaudeBinaryLocator {
        ClaudeBinaryLocator(home: home, systemPaths: [], shellLookup: { shell })
    }

    func testNothingInstalledReturnsNil() async {
        let found = await locator().locate()
        XCTAssertNil(found)
    }

    func testFindsNativeInstallerPath() async throws {
        let bin = try makeFile(".local/bin/claude")
        let found = await locator().locate()
        XCTAssertEqual(found?.path, bin.path)
    }

    func testLocalInstallWinsOverNativeInstaller() async throws {
        let local = try makeFile(".claude/local/claude")
        try makeFile(".local/bin/claude")
        let found = await locator().locate()
        XCTAssertEqual(found?.path, local.path)
    }

    func testNonExecutableFileIsSkipped() async throws {
        try makeFile(".claude/local/claude", executable: false)
        let bin = try makeFile(".local/bin/claude")
        let found = await locator().locate()
        XCTAssertEqual(found?.path, bin.path)
    }

    /// Tri numérique : v9 < v18 < v20 (un tri lexical mettrait v9 en tête).
    func testNewestNvmVersionWins() async throws {
        try makeFile(".nvm/versions/node/v9.0.0/bin/claude")
        let newest = try makeFile(".nvm/versions/node/v20.11.0/bin/claude")
        try makeFile(".nvm/versions/node/v18.2.0/bin/claude")
        let found = await locator().locate()
        XCTAssertEqual(found?.path, newest.path)
    }

    func testSystemPathsAreCheckedAfterHomePaths() async throws {
        let system = try makeFile("opt/homebrew/bin/claude")
        let sut = ClaudeBinaryLocator(home: home, systemPaths: [system.path],
                                      shellLookup: { nil })
        let found = await sut.locate()
        XCTAssertEqual(found?.path, system.path)
    }

    func testFallsBackToShellLookup() async throws {
        let custom = try makeFile("somewhere/else/claude")
        let found = await locator(shell: custom.path).locate()
        XCTAssertEqual(found?.path, custom.path)
    }

    /// Le shell peut répondre un chemin périmé : on ne l'accepte que s'il
    /// désigne vraiment un exécutable.
    func testShellLookupPointingToMissingFileIsRejected() async {
        let found = await locator(shell: home.appendingPathComponent("nope").path).locate()
        XCTAssertNil(found)
    }

    func testShellLookupNotCalledWhenKnownPathExists() async throws {
        try makeFile(".local/bin/claude")
        let called = expectation(description: "shell lookup")
        called.isInverted = true
        let sut = ClaudeBinaryLocator(home: home, systemPaths: [],
                                      shellLookup: { called.fulfill(); return nil })
        _ = await sut.locate()
        await fulfillment(of: [called], timeout: 0.1)
    }

    // MARK: - Sortie du shell

    /// Un `.zshrc` bavard peut imprimer n'importe quoi avant la réponse.
    func testParseKeepsLastAbsolutePathLine() {
        let out = "Welcome!\nnvm: using node v20\n/Users/me/.local/bin/claude\n"
        XCTAssertEqual(ClaudeBinaryLocator.parseShellOutput(out), "/Users/me/.local/bin/claude")
    }

    /// `command -v` sur un alias répond « alias claude=… », pas un chemin.
    func testParseRejectsAliasAndEmptyOutput() {
        XCTAssertNil(ClaudeBinaryLocator.parseShellOutput("alias claude='npx claude'\n"))
        XCTAssertNil(ClaudeBinaryLocator.parseShellOutput(""))
    }

    // MARK: - Shell réel (faux binaire de shell)

    func testLoginShellLookupReadsShellOutput() async throws {
        let shell = try makeFile("fake-shell", contents: "#!/bin/sh\necho noise\necho /x/claude\n")
        let out = await ClaudeBinaryLocator.loginShellLookup(shell: shell.path, timeout: 5)
        XCTAssertEqual(out, "/x/claude")
    }

    /// Un `.zshrc` qui bloque ne doit pas geler la détection.
    func testLoginShellLookupTimesOut() async throws {
        let shell = try makeFile("slow-shell", contents: "#!/bin/sh\nsleep 30\necho /x/claude\n")
        let start = Date()
        let out = await ClaudeBinaryLocator.loginShellLookup(shell: shell.path, timeout: 0.5)
        XCTAssertNil(out)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
}
