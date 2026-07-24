import XCTest
@testable import ExtendReality

@MainActor
final class YouTubeDownloadStoreTests: XCTestCase {
    func testImportedVideoPersistsAndCanBeReadFromDisk() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = root.appendingPathComponent("source.mov", isDirectory: false)
        let downloadsURL = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("local-video".utf8).write(to: sourceURL)

        let store = YouTubeDownloadStore(directoryURL: downloadsURL)
        try store.importVideo(from: sourceURL)

        let imported = try XCTUnwrap(store.downloads.first)
        XCTAssertEqual(imported.title, "source")
        XCTAssertEqual(imported.channelTitle, "On My Device")
        XCTAssertNotNil(store.fileURL(for: imported))

        let restoredStore = YouTubeDownloadStore(directoryURL: downloadsURL)
        XCTAssertEqual(restoredStore.downloads, [imported])
        XCTAssertNotNil(restoredStore.fileURL(for: imported))
    }

    func testDeletingDownloadRemovesManifestEntryAndFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceURL = root.appendingPathComponent("source.mp4", isDirectory: false)
        let downloadsURL = root.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("local-video".utf8).write(to: sourceURL)

        let store = YouTubeDownloadStore(directoryURL: downloadsURL)
        try store.importVideo(from: sourceURL)
        let imported = try XCTUnwrap(store.downloads.first)
        let storedURL = try XCTUnwrap(store.fileURL(for: imported))

        store.delete(imported)

        XCTAssertTrue(store.downloads.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
    }

    func testDownloadQualityPersists() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "YouTubeDownloadStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = YouTubeDownloadStore(directoryURL: root, userDefaults: defaults)
        store.selectedQuality = .p480

        let restoredStore = YouTubeDownloadStore(directoryURL: root, userDefaults: defaults)
        XCTAssertEqual(restoredStore.selectedQuality, .p480)
        XCTAssertEqual(restoredStore.selectedQuality.maximumResolution, 480)
    }

    func testDownloadActivityFormatsRealProgress() {
        let activity = YouTubeDownloadActivity.downloading(
            progress: 0.42,
            receivedBytes: 42_000_000,
            totalBytes: 100_000_000
        )

        XCTAssertEqual(activity.title, "42%")
        XCTAssertEqual(activity.progress, 0.42)
        XCTAssertNotNil(activity.byteDetail)
    }
}
