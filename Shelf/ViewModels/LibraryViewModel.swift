import Foundation
import CoreData
import SwiftUI
import UniformTypeIdentifiers

/// Controls library state: scanning, filtering, sorting, and grouping.
/// Supports multiple libraries — each pointing to a different audiobooks folder.
@MainActor
class LibraryViewModel: ObservableObject {

    // MARK: - Published State

    @Published var books: [Book] = []
    @Published var searchText: String = ""
    @Published var sortOrder: SortOrder = .title
    @Published var selectedCategory: SidebarCategory = .allBooks
    @Published var isScanning: Bool = false
    @Published var scanResult: ScanResult?

    /// Background metadata extraction progress
    @Published var isLoadingMetadata: Bool = false
    @Published var metadataProgress: Int = 0
    @Published var metadataTotal: Int = 0

    /// Tracks the background metadata task so it can be cancelled on re-scan
    private var metadataTask: Task<Void, Never>?

    /// All libraries the user has added
    @Published var libraries: [Library] = []
    /// The currently selected library (determines which books are shown)
    @Published var activeLibrary: Library?

    // MARK: - Grouping Data & Pre-computed Counts

    @Published var authors: [String] = []
    @Published var genres: [String] = []
    @Published var years: [Int32] = []

    /// Pre-computed sidebar counts — avoids re-filtering 1,800+ books on every render
    @Published var inProgressCount: Int = 0
    @Published var completedCount: Int = 0
    @Published var authorCounts: [String: Int] = [:]
    @Published var genreCounts: [String: Int] = [:]
    @Published var yearCounts: [Int32: Int] = [:]
    @Published var smartCollectionCounts: [SmartCollection: Int] = [:]

    // MARK: - View Mode

    enum ViewMode: String, CaseIterable {
        case grid = "Grid"
        case bigGrid = "Big Grid"
        case list = "List"

        var icon: String {
            switch self {
            case .grid: return "square.grid.2x2"
            case .bigGrid: return "square.grid.3x1.below.line.grid.1x2"
            case .list: return "list.bullet"
            }
        }
    }

    @Published var viewMode: ViewMode = .grid

    // MARK: - Sort Options

    enum SortOrder: String, CaseIterable {
        case title = "Title"
        case author = "Author"
        case year = "Year"
        case duration = "Duration"
        case recentlyPlayed = "Recently Played"
        case progress = "Progress"
    }

    // MARK: - Sidebar Categories

    enum SidebarCategory: Hashable {
        case allBooks
        case inProgress
        case completed
        case smartCollection(SmartCollection)
        case author(String)
        case genre(String)
        case year(Int32)
    }

    // MARK: - Smart Collections

    enum SmartCollection: String, CaseIterable, Hashable {
        case recentlyAdded = "Recently Added"
        case shortBooks = "Short Books"
        case longBooks = "Long Books"
        case notStarted = "Not Started"
        case nearlyFinished = "Nearly Finished"

        var icon: String {
            switch self {
            case .recentlyAdded: return "clock"
            case .shortBooks: return "hourglass.bottomhalf.filled"
            case .longBooks: return "hourglass.tophalf.filled"
            case .notStarted: return "circle"
            case .nearlyFinished: return "flag.checkered"
            }
        }

        /// Returns true if the book matches this smart collection's criteria
        func matches(_ book: Book) -> Bool {
            switch self {
            case .recentlyAdded:
                guard let modDate = book.fileModDate else { return false }
                return modDate > Calendar.current.date(byAdding: .day, value: -30, to: Date())!
            case .shortBooks:
                return book.duration > 0 && book.duration < 4 * 3600
            case .longBooks:
                return book.duration > 10 * 3600
            case .notStarted:
                return book.playbackPosition == 0 && !book.isCompleted
            case .nearlyFinished:
                return book.progress > 0.85 && !book.isCompleted && book.duration > 0
            }
        }
    }

    // MARK: - Init

    private let persistence: PersistenceController

    /// Keeps the security-scoped resource active so AVPlayer can read files
    private var activeFolderURL: URL?

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence

        // Migrate from single-library UserDefaults if needed
        migrateFromSingleLibrary()

        // Load all libraries and restore the last-used one
        loadLibraries()
        restoreLastLibrary()

        // Load books for the active library and start folder access
        loadBooks()
        startFolderAccess()
    }

    // MARK: - Migration

    /// One-time migration: converts the old single-folder UserDefaults storage
    /// into a Library entity so existing users keep their books.
    private func migrateFromSingleLibrary() {
        let context = persistence.container.viewContext

        // Check if any Library entities already exist
        let request: NSFetchRequest<Library> = Library.fetchRequest()
        let count = (try? context.count(for: request)) ?? 0
        if count > 0 { return } // Already migrated or fresh multi-library user

        // Check if there's an old single-library path in UserDefaults
        guard let oldPath = UserDefaults.standard.string(forKey: "libraryFolderPath") else { return }

        // Create a Library entity from the old data
        let library = Library(context: context)
        library.id = UUID()
        library.folderPath = oldPath
        library.name = URL(fileURLWithPath: oldPath).lastPathComponent
        library.createdDate = Date()
        library.lastOpenedDate = Date()

        // Copy the security-scoped bookmark if available
        if let bookmarkData = UserDefaults.standard.data(forKey: "libraryFolderBookmark") {
            library.folderBookmark = bookmarkData
        }

        // Associate ALL existing Book entities with this library
        let bookRequest: NSFetchRequest<Book> = Book.fetchRequest()
        if let existingBooks = try? context.fetch(bookRequest) {
            for book in existingBooks {
                book.library = library
            }
        }

        persistence.save()
        print("Migrated single library: \(oldPath)")
    }

    // MARK: - Library Management

    /// Loads all Library entities from Core Data, sorted by name
    func loadLibraries() {
        let request: NSFetchRequest<Library> = Library.fetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \Library.name, ascending: true)]
        do {
            libraries = try persistence.container.viewContext.fetch(request)
        } catch {
            print("Failed to fetch libraries: \(error)")
        }
    }

    /// Restores the library with the most recent lastOpenedDate
    private func restoreLastLibrary() {
        guard !libraries.isEmpty else { return }
        activeLibrary = libraries
            .sorted { ($0.lastOpenedDate ?? .distantPast) > ($1.lastOpenedDate ?? .distantPast) }
            .first
    }

    /// Switches to a different library: stops folder access, sets active,
    /// updates lastOpenedDate, and reloads books.
    func switchToLibrary(_ library: Library) {
        stopFolderAccess()
        activeLibrary = library
        library.lastOpenedDate = Date()
        persistence.save()
        selectedCategory = .allBooks
        loadBooks()
        startFolderAccess()
    }

    /// Opens an NSOpenPanel to pick a new audiobooks folder, creates a Library entity,
    /// switches to it, and scans.
    func addLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Select an Audiobooks Folder"
        panel.message = "Choose a folder containing your audiobook files (m4b, m4a, mp3)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let newPath = url.path

        // Reject duplicates — don't add the same folder twice
        if libraries.contains(where: { $0.folderPath == newPath }) {
            let alert = NSAlert()
            alert.messageText = "Library Already Exists"
            alert.informativeText = "This folder is already added as a library."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let context = persistence.container.viewContext
        let library = Library(context: context)
        library.id = UUID()
        library.folderPath = newPath
        library.name = url.lastPathComponent
        library.createdDate = Date()
        library.lastOpenedDate = Date()

        // Save a security-scoped bookmark
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            library.folderBookmark = bookmarkData
        } catch {
            print("Failed to save bookmark: \(error)")
        }

        persistence.save()
        loadLibraries()
        switchToLibrary(library)

        // Scan the new library
        Task { await scanLibrary() }
    }

    /// Removes a library (deletes entity — cascade removes book metadata, NOT files on disk).
    /// Switches to the next available library, or sets active to nil.
    func removeLibrary(_ library: Library) {
        let context = persistence.container.viewContext
        let wasActive = (library == activeLibrary)

        context.delete(library)
        persistence.save()
        loadLibraries()

        if wasActive {
            if let next = libraries.first {
                switchToLibrary(next)
            } else {
                stopFolderAccess()
                activeLibrary = nil
                books = []
                authors = []
                genres = []
                years = []
            }
        }
    }

    /// Opens an NSOpenPanel to pick a new folder for an existing library (e.g., folder was moved).
    /// Updates the path and bookmark, and rescans if it's the active library.
    func relinkLibrary(_ library: Library) {
        let panel = NSOpenPanel()
        panel.title = "Relink \"\(library.displayName)\""
        panel.message = "Choose the new location for this audiobooks folder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        library.folderPath = url.path

        // Update the security-scoped bookmark
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            library.folderBookmark = bookmarkData
        } catch {
            print("Failed to save bookmark: \(error)")
        }

        persistence.save()
        loadLibraries()

        // If this is the active library, restart access and rescan
        if library == activeLibrary {
            startFolderAccess()
            Task { await scanLibrary() }
        }
    }

    /// Renames a library
    func renameLibrary(_ library: Library, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        library.name = trimmed
        persistence.save()
        loadLibraries()
    }

    /// The folder path of the active library (used by UI)
    var libraryFolderPath: String? {
        activeLibrary?.folderPath
    }

    // MARK: - Security-Scoped Folder Access

    /// Starts security-scoped access to the active library's bookmarked folder.
    /// Keeps it alive so AVPlayer can read audio files at any time.
    func startFolderAccess() {
        // Stop any previous access
        stopFolderAccess()

        guard let bookmarkData = activeLibrary?.folderBookmark else { return }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                let newBookmark = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                activeLibrary?.folderBookmark = newBookmark
                persistence.save()
            }

            if url.startAccessingSecurityScopedResource() {
                activeFolderURL = url
            }
        } catch {
            print("Failed to start folder access: \(error)")
        }
    }

    /// Stops security-scoped access (called on library switch or app quit)
    func stopFolderAccess() {
        activeFolderURL?.stopAccessingSecurityScopedResource()
        activeFolderURL = nil
    }

    // MARK: - Library Scanning

    /// Scans the active library's folder using two passes:
    /// Pass 1 (fast): discovers files and creates Book entities — books appear immediately
    /// Pass 2 (background): extracts metadata progressively with a progress bar
    func scanLibrary() async {
        guard let library = activeLibrary else { return }

        // Cancel any in-progress metadata extraction from a previous scan
        metadataTask?.cancel()
        metadataTask = nil

        // Ensure folder access is active
        if activeFolderURL == nil {
            startFolderAccess()
        }

        guard let folderURL = activeFolderURL ?? fallbackFolderURL() else { return }

        let context = persistence.container.viewContext

        // --- Pass 1: Fast file discovery (no AVFoundation, no network) ---
        isScanning = true
        let filesResult = LibraryScanner.scanFiles(folder: folderURL, library: library, context: context)
        loadBooks()   // Books appear in the grid right away with filename-based titles
        isScanning = false

        print("Library scan (\(library.displayName)): \(filesResult.summary)")

        // --- Pass 2: Background metadata extraction ---
        let booksToProcess = filesResult.booksNeedingMetadata
        guard !booksToProcess.isEmpty else { return }

        isLoadingMetadata = true
        metadataProgress = 0
        metadataTotal = booksToProcess.count

        metadataTask = Task {
            await LibraryScanner.extractMetadataInBackground(
                books: booksToProcess,
                context: context,
                onProgress: { [weak self] completed, total in
                    self?.metadataProgress = completed
                    self?.metadataTotal = total
                    // Reload books periodically so covers and titles update in the grid
                    self?.loadBooks()
                }
            )

            // Final reload and cleanup
            self.loadBooks()
            self.isLoadingMetadata = false
            self.metadataTask = nil
            print("Metadata extraction complete for \(library.displayName)")
        }
    }

    /// Fallback: returns a plain file URL (works outside sandbox)
    private func fallbackFolderURL() -> URL? {
        guard let path = activeLibrary?.folderPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Data Loading

    /// Loads books for the active library from Core Data and updates grouping data + counts
    func loadBooks() {
        guard let library = activeLibrary else {
            books = []
            authors = []
            genres = []
            years = []
            inProgressCount = 0
            completedCount = 0
            authorCounts = [:]
            genreCounts = [:]
            yearCounts = [:]
            smartCollectionCounts = [:]
            return
        }

        let request: NSFetchRequest<Book> = Book.fetchRequest()
        request.predicate = NSPredicate(format: "library == %@", library)
        // Batch fetching — Core Data loads objects in chunks instead of all at once
        request.fetchBatchSize = 50
        do {
            let allBooks = try persistence.container.viewContext.fetch(request)

            // Build all grouping data and counts in a single pass
            var authorCountMap: [String: Int] = [:]
            var genreCountMap: [String: Int] = [:]
            var yearCountMap: [Int32: Int] = [:]
            var smartCounts: [SmartCollection: Int] = [:]
            var ipCount = 0
            var cCount = 0

            for book in allBooks {
                // Category counts
                if book.isInProgress { ipCount += 1 }
                if book.isCompleted { cCount += 1 }

                // Grouping counts
                if let a = book.author, !a.isEmpty {
                    authorCountMap[a, default: 0] += 1
                }
                if let g = book.genre, !g.isEmpty {
                    genreCountMap[g, default: 0] += 1
                }
                if book.year > 0 {
                    yearCountMap[book.year, default: 0] += 1
                }

                // Smart collection counts
                for collection in SmartCollection.allCases {
                    if collection.matches(book) {
                        smartCounts[collection, default: 0] += 1
                    }
                }
            }

            authors = authorCountMap.keys.sorted()
            genres = genreCountMap.keys.sorted()
            years = yearCountMap.keys.sorted(by: >)

            authorCounts = authorCountMap
            genreCounts = genreCountMap
            yearCounts = yearCountMap
            smartCollectionCounts = smartCounts
            inProgressCount = ipCount
            completedCount = cCount

            books = allBooks
        } catch {
            print("Failed to fetch books: \(error)")
        }
    }

    // MARK: - Filtered & Sorted Books

    /// Returns books filtered by search, category, and sorted
    var filteredBooks: [Book] {
        var result = books

        // Filter by category
        switch selectedCategory {
        case .allBooks:
            break
        case .inProgress:
            result = result.filter { $0.isInProgress }
        case .completed:
            result = result.filter { $0.isCompleted }
        case .smartCollection(let collection):
            result = result.filter { collection.matches($0) }
        case .author(let name):
            result = result.filter { $0.author == name }
        case .genre(let name):
            result = result.filter { $0.genre == name }
        case .year(let yr):
            result = result.filter { $0.year == yr }
        }

        // Filter by search text
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter { book in
                (book.title?.lowercased().contains(query) ?? false) ||
                (book.author?.lowercased().contains(query) ?? false) ||
                (book.genre?.lowercased().contains(query) ?? false)
            }
        }

        // Sort
        switch sortOrder {
        case .title:
            result.sort { ($0.displayTitle) < ($1.displayTitle) }
        case .author:
            result.sort { $0.displayAuthor < $1.displayAuthor }
        case .year:
            result.sort { $0.year > $1.year }
        case .duration:
            result.sort { $0.duration < $1.duration }
        case .recentlyPlayed:
            result.sort { ($0.lastPlayedDate ?? .distantPast) > ($1.lastPlayedDate ?? .distantPast) }
        case .progress:
            result.sort { $0.progress > $1.progress }
        }

        return result
    }

    // MARK: - Book Actions

    /// Resets a book's playback progress to zero
    func resetProgress(for book: Book) {
        book.playbackPosition = 0
        book.lastPlayedDate = nil
        book.isCompleted = false
        persistence.save()
        notifyChange()
    }

    /// Marks a book as completed and resets its progress
    func markCompleted(_ book: Book) {
        book.isCompleted = true
        book.playbackPosition = 0
        persistence.save()
        notifyChange()
    }

    /// Unmarks a book as completed (moves it back to the library)
    func markNotCompleted(_ book: Book) {
        book.isCompleted = false
        persistence.save()
        notifyChange()
    }

    /// Defers objectWillChange to the next run loop tick to avoid
    /// "Publishing changes from within view updates" warnings
    private func notifyChange() {
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    /// Reveals the book's file in Finder
    func showInFinder(_ book: Book) {
        guard let path = book.filePath else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Copies the book's title to the clipboard
    func copyTitle(_ book: Book) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(book.displayTitle, forType: .string)
    }

    // MARK: - Import / Export

    /// Exports all book progress and bookmarks to a JSON file via NSSavePanel
    func exportProgress() {
        guard let data = ProgressExporter.exportProgress(books: books) else { return }

        let panel = NSSavePanel()
        panel.title = "Export Audiobook Progress"
        panel.nameFieldStringValue = "audiobook-progress.json"
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try data.write(to: url)
        } catch {
            print("Export failed: \(error)")
        }
    }

    /// Imports progress from a JSON file via NSOpenPanel, then shows a summary alert
    func importProgress() {
        let panel = NSOpenPanel()
        panel.title = "Import Audiobook Progress"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let context = persistence.container.viewContext
            guard let result = ProgressExporter.importProgress(from: data, context: context) else {
                showImportAlert(message: "Could not read the progress file. It may be in an unsupported format.")
                return
            }

            loadBooks()

            var summary = "Updated \(result.booksUpdated) book(s)."
            if result.bookmarksCreated > 0 {
                summary += "\nImported \(result.bookmarksCreated) bookmark(s)."
            }
            if result.booksNotFound > 0 {
                summary += "\nSkipped \(result.booksNotFound) book(s) not in library."
            }
            showImportAlert(message: summary)
        } catch {
            showImportAlert(message: "Failed to read file: \(error.localizedDescription)")
        }
    }

    /// Shows an alert with import results
    private func showImportAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Import Complete"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
