import XCTest
@testable import RecorderCore

/// Install-state management behind the Settings model manager. Uses an
/// injected root so the user's real model folder is never touched.
final class ModelLibraryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("onyx-models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func install(_ asset: ModelAsset, bytes: Int) throws {
        let dir = root.appendingPathComponent(asset.relativeInstallPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: bytes)
            .write(to: dir.appendingPathComponent("model.mlmodelc"))
    }

    func test_installStateAndRecursiveSize() throws {
        let turbo = ModelManifest.whisperLargeV3Turbo
        XCTAssertFalse(ModelLibrary.isInstalled(turbo, root: root))
        XCTAssertNil(ModelLibrary.installedSizeBytes(turbo, root: root))

        try install(turbo, bytes: 4096)
        XCTAssertTrue(ModelLibrary.isInstalled(turbo, root: root))
        let size = try XCTUnwrap(ModelLibrary.installedSizeBytes(turbo, root: root))
        XCTAssertGreaterThanOrEqual(size, 4096)
    }

    func test_delete_removesModel_andIsIndependentPerVariant() throws {
        let turbo = ModelManifest.whisperLargeV3Turbo
        let large = ModelManifest.whisperLargeV3
        try install(turbo, bytes: 10)
        try install(large, bytes: 10)

        try ModelLibrary.delete(turbo, root: root)

        XCTAssertFalse(ModelLibrary.isInstalled(turbo, root: root))
        XCTAssertTrue(ModelLibrary.isInstalled(large, root: root),
                      "deleting one variant must not touch the other")
    }

    func test_whisperVariants_containsBothKnownModels() {
        XCTAssertEqual(ModelLibrary.whisperVariants.map(\.id),
                       [ModelManifest.whisperLargeV3Turbo.id,
                        ModelManifest.whisperLargeV3.id])
    }
}
