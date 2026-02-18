import Foundation
import CoreData

/// Scans a folder for audiobook files and populates Core Data
class LibraryScanner {

    // Audio file extensions we support
    private static let supportedExtensions: Set<String> = ["m4b", "m4a", "mp3"]

    /// Scans the given folder recursively for audiobook files, scoped to a specific library.
    /// - Adds new files to Core Data (associated with the library)
    /// - Removes entries for deleted files
    /// - Re-extracts metadata for files whose modification date changed
    /// - Skips unchanged files entirely
    static func scan(folder: URL, library: Library, context: NSManagedObjectContext) async -> ScanResult {
        var result = ScanResult()

        // Find all audio files in the folder
        let audioFiles = findAudioFiles(in: folder)
        result.totalFilesFound = audioFiles.count

        // Fetch existing books for THIS library only
        let existingBooks = fetchBooks(for: library, context: context)
        var existingByPath: [String: Book] = [:]
        for book in existingBooks {
            if let path = book.filePath {
                existingByPath[path] = book
            }
        }

        let foundPaths = Set(audioFiles.map { $0.path })

        // Remove books whose files no longer exist
        for (path, book) in existingByPath {
            if !foundPaths.contains(path) {
                context.delete(book)
                result.removed += 1
            }
        }

        // Process each audio file
        for fileURL in audioFiles {
            let path = fileURL.path

            if let existing = existingByPath[path] {
                // Check if file was modified since last scan
                let currentModDate = fileModificationDate(for: fileURL)
                let hasMissingMetadata = existing.genre == nil || existing.genre?.isEmpty == true
                if !hasMissingMetadata,
                   let savedModDate = existing.fileModDate,
                   let currentModDate = currentModDate,
                   savedModDate >= currentModDate {
                    // File unchanged and metadata complete — skip
                    result.skipped += 1
                    continue
                }
                // File changed — re-extract metadata
                let metadata = await MetadataExtractor.extract(from: fileURL)
                updateBook(existing, with: metadata, filePath: path, modDate: fileModificationDate(for: fileURL))
                result.updated += 1
            } else {
                // New file — extract metadata and create entry
                let metadata = await MetadataExtractor.extract(from: fileURL)
                let book = Book(context: context)
                book.id = UUID()
                book.filePath = path
                book.library = library
                updateBook(book, with: metadata, filePath: path, modDate: fileModificationDate(for: fileURL))
                result.added += 1
            }
        }

        // Save changes
        do {
            if context.hasChanges {
                try context.save()
            }
        } catch {
            print("Failed to save after scan: \(error)")
        }

        return result
    }

    // MARK: - Private Helpers

    /// Recursively finds all supported audio files in a folder
    private static func findAudioFiles(in folder: URL) -> [URL] {
        var audioFiles: [URL] = []

        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return audioFiles
        }

        for case let fileURL as URL in enumerator {
            let ext = fileURL.pathExtension.lowercased()
            if supportedExtensions.contains(ext) {
                audioFiles.append(fileURL)
            }
        }

        return audioFiles
    }

    /// Fetches Book entities for a specific library
    private static func fetchBooks(for library: Library, context: NSManagedObjectContext) -> [Book] {
        let request: NSFetchRequest<Book> = Book.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@", library)
        do {
            return try context.fetch(request)
        } catch {
            print("Failed to fetch books: \(error)")
            return []
        }
    }

    /// Returns the modification date of a file
    private static func fileModificationDate(for url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    /// Updates a Book entity with extracted metadata
    private static func updateBook(_ book: Book, with metadata: AudiobookMetadata, filePath: String, modDate: Date?) {
        book.title = metadata.title
        book.author = metadata.author
        book.genre = metadata.genre
        book.year = metadata.year
        book.duration = metadata.duration
        book.coverArtData = metadata.coverArtData
        book.hasChapters = metadata.hasChapters
        book.fileModDate = modDate
        // Don't overwrite playbackPosition or lastPlayedDate — those are user data
    }
}

/// Results from a library scan operation
struct ScanResult {
    var totalFilesFound: Int = 0
    var added: Int = 0
    var updated: Int = 0
    var removed: Int = 0
    var skipped: Int = 0

    var summary: String {
        "Found \(totalFilesFound) files: \(added) added, \(updated) updated, \(removed) removed, \(skipped) unchanged"
    }
}
