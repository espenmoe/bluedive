import Foundation
import ImageIO
import SwiftData
import Testing
@testable import BlueDive

/// End to end, with a real Lightroom export: importing, re-importing a copy, a newer version
/// (metadata re-saved, as a Lightroom republish does), an older one and a renamed variant.
/// The variants are written with `CGImageDestinationCopyImageSource`, which changes only the
/// metadata. Runs only where the tester's sample folder is present.
@MainActor
struct PhotoReimportImportTests {

    /// Nonisolated: read by the `.enabled(if:)` condition, outside the main actor.
    nonisolated static let sample = URL(fileURLWithPath: "/Users/stevehoule/Downloads/DiveBlueImages/PANA0202.jpg")

    /// A copy of the sample in a folder of its own (same file name), with the edit and export
    /// dates set to `edited` and an added keyword when given.
    private func variant(_ edited: String?, keyword: String? = nil, name: String = "PANA0202.jpg") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        guard let edited else {
            try FileManager.default.copyItem(at: Self.sample, to: url)
            return url
        }
        let source = try #require(CGImageSourceCreateWithURL(Self.sample as CFURL, nil))
        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap(CGImageMetadataCreateMutableCopy))
        for path in ["xmp:MetadataDate", "xmp:ModifyDate", "tiff:DateTime"] {
            CGImageMetadataSetValueWithPath(metadata, nil, path as CFString, edited as CFString)
        }
        if let keyword, let tag = CGImageMetadataCopyTagWithPath(metadata, nil, "dc:subject" as CFString),
           let values = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] {
            let keywords = values.compactMap { CGImageMetadataTagCopyValue($0) as? String } + [keyword]
            CGImageMetadataSetValueWithPath(metadata, nil, "dc:subject" as CFString, keywords as CFArray)
        }
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        let options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true]
        #expect(CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil))
        return url
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: sample.path)))
    func lightroomRepublishUpdatesTheStoredPhoto() async throws {
        let container = try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                                              cloudKitDatabase: .none))
        let context = container.mainContext
        // The sample was taken 2026-08-22 11:38:26 (wall clock): a dive around it.
        let start = try #require(WallClock.storedDate(from: DateComponents(year: 2026, month: 8, day: 22, hour: 11, minute: 20, second: 0)))
        let dive = Dive(timestamp: start)
        dive.duration = 60
        context.insert(dive)
        try context.save()
        let diveID = dive.persistentModelID

        // 1. First import.
        let first = await PhotoImporter.importPhotos([.file(try variant(nil))], toDiveWith: diveID, container: container)
        #expect(first.imported == 1)
        let photoID = try #require(first.importedPhotoIDs.first)

        // 2. The same file copied to another folder: already in BlueDive.
        let copy = await PhotoImporter.importPhotos([.file(try variant(nil))], toDiveWith: diveID, container: container)
        #expect(copy.duplicates == 1 && copy.imported == 0)

        // 3. Republished later with a new keyword: the stored photo is replaced in place.
        let newer = await PhotoImporter.importPhotos([.file(try variant("2026-10-10T10:00:00+02:00", keyword: "Republished"))],
                                                     toDiveWith: diveID, container: container)
        #expect(newer.updated == 1 && newer.imported == 0 && newer.questions.isEmpty)
        #expect(newer.updatedPhotoIDs == [photoID])
        let check = ModelContext(container)
        let photos = try check.fetch(FetchDescriptor<DivePhoto>())
        #expect(photos.count == 1)
        #expect(photos.first?.id == photoID)
        #expect(photos.first?.iptcKeywords?.contains("Republished") == true)

        // 4. An older export: skipped, the newer version stays.
        let older = await PhotoImporter.importPhotos([.file(try variant("2026-01-01T10:00:00+01:00"))],
                                                     toDiveWith: diveID, container: container)
        #expect(older.olderSkipped == 1 && older.updated == 0)

        // 5. A variant under another name (a Lightroom virtual copy): asked about, not replaced.
        let renamed = await PhotoImporter.importPhotos([.file(try variant("2026-10-11T10:00:00+02:00", name: "PANA0202-2.jpg"))],
                                                       toDiveWith: diveID, container: container)
        #expect(renamed.questions.map(\.reason) == [.differentFilename])
        #expect(renamed.imported == 0 && renamed.updated == 0)

        // 6. Answered "Keep both": added as a second photo; the first is untouched.
        let kept = await PhotoImporter.answer(renamed.questions.map { ($0, .keepBoth) }, container: container)
        #expect(kept.imported == 1)
        #expect(try ModelContext(container).fetch(FetchDescriptor<DivePhoto>()).count == 2)
    }

    /// One import with the same new version under two names: the renamed file asks, the
    /// original name updates; answering "Update" then finds the identical file already stored.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: sample.path)))
    func updateAnswerWithTheStoredFileIsAlready() async throws {
        let container = try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                                              cloudKitDatabase: .none))
        let start = try #require(WallClock.storedDate(from: DateComponents(year: 2026, month: 8, day: 22, hour: 11, minute: 20, second: 0)))
        let dive = Dive(timestamp: start)
        dive.duration = 60
        container.mainContext.insert(dive)
        try container.mainContext.save()
        let diveID = dive.persistentModelID
        let first = await PhotoImporter.importPhotos([.file(try variant(nil))], toDiveWith: diveID, container: container)
        let photoID = try #require(first.importedPhotoIDs.first)

        let newer = try variant("2026-10-10T10:00:00+02:00")
        let renamed = newer.deletingLastPathComponent().appendingPathComponent("PANA0202-Edit.jpg")
        try FileManager.default.copyItem(at: newer, to: renamed)
        let both = await PhotoImporter.importPhotos([.file(renamed), .file(newer)], toDiveWith: diveID, container: container)
        #expect(both.updated == 1 && both.questions.map(\.reason) == [.differentFilename])

        let answered = await PhotoImporter.answer(both.questions.map { ($0, .update(photoID)) }, container: container)
        #expect(answered.duplicates == 1 && answered.updated == 0)
    }

    /// "Update" chosen for a stored photo deleted since the question (e.g. on another device):
    /// the file is added as a new photo instead of being lost.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: sample.path)))
    func updateOfADeletedPhotoKeepsTheFile() async throws {
        let container = try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                                              cloudKitDatabase: .none))
        let start = try #require(WallClock.storedDate(from: DateComponents(year: 2026, month: 8, day: 22, hour: 11, minute: 20, second: 0)))
        let dive = Dive(timestamp: start)
        dive.duration = 60
        container.mainContext.insert(dive)
        try container.mainContext.save()
        let diveID = dive.persistentModelID
        let first = await PhotoImporter.importPhotos([.file(try variant(nil))], toDiveWith: diveID, container: container)
        let photoID = try #require(first.importedPhotoIDs.first)

        let renamed = await PhotoImporter.importPhotos([.file(try variant("2026-10-10T10:00:00+02:00", name: "PANA0202-2.jpg"))],
                                                       toDiveWith: diveID, container: container)
        #expect(renamed.questions.first?.candidateDetails.map(\.filename) == ["PANA0202.jpg"])
        let context = ModelContext(container)
        context.delete(try #require(PhotoImporter.fetchPhoto(photoID, in: context)))
        try context.save()

        let answered = await PhotoImporter.answer(renamed.questions.map { ($0, .update(photoID)) }, container: container)
        #expect(answered.imported == 1 && answered.updated == 0 && answered.failedToSave == 0)
        #expect(try ModelContext(container).fetch(FetchDescriptor<DivePhoto>()).count == 1)
    }

    /// The manual test set (BlueDive-ReimportTest/README.txt), checked against the README's
    /// expected results with a copy of Espen's dive #580.
    nonisolated static let testSet = URL(fileURLWithPath: "/Users/stevehoule/Downloads/BlueDive-ReimportTest")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: testSet.path)))
    func manualTestSetGivesTheExpectedResults() async throws {
        let container = try ModelContainer(for: Schema(BlueDiveApp.appModelTypes),
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                                              cloudKitDatabase: .none))
        let context = container.mainContext
        let start = try #require(WallClock.storedDate(from: DateComponents(year: 2026, month: 3, day: 1, hour: 9, minute: 4, second: 0)))
        let dive = Dive(timestamp: start)
        dive.duration = 70
        context.insert(dive)
        try context.save()
        func run(_ folder: String) async throws -> PhotoImporter.Result {
            let urls = try FileManager.default.contentsOfDirectory(at: Self.testSet.appendingPathComponent(folder),
                                                                   includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "jpg" }
            return await PhotoImporter.importPhotos(urls.map { .file($0) }, toDiveWith: dive.persistentModelID, container: container)
        }
        let original = try await run("1-original")
        #expect(original.imported == 8)
        let republished = try await run("2-republished")
        #expect(republished.updated == 8 && republished.imported == 0 && republished.questions.isEmpty)
        let cropped = try await run("3-cropped")
        #expect(cropped.updated == 1)
        let older = try await run("4-older-copy")
        #expect(older.olderSkipped == 1)
        let virtual = try await run("5-virtual-copy")
        #expect(virtual.questions.map(\.reason) == [.differentFilename])
        let again = try await run("6-same-file-again")
        #expect(again.duplicates == 1)
        let web = try await run("7-web-export")
        #expect(web.questions.map(\.reason) == [.smallerWithoutDate])
        #expect(try ModelContext(container).fetch(FetchDescriptor<DivePhoto>()).count == 8)
    }
}
