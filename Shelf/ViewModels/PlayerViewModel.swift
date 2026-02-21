import Foundation
import SwiftUI
import Combine
import CoreData

/// Bridges the AudioPlayerService with the UI, manages chapter data
@MainActor
class PlayerViewModel: ObservableObject {

    // MARK: - Published State

    @Published var currentBook: Book?
    @Published var chapters: [ChapterInfo] = []
    @Published var currentChapterIndex: Int = 0
    @Published var showChapterList: Bool = false
    @Published var bookmarks: [Bookmark] = []
    @Published var showBookmarkList: Bool = false
    @Published var showAddBookmark: Bool = false

    // Cloud download state (in-memory only, not persisted)
    @Published var downloadingBookID: NSManagedObjectID?
    @Published var downloadProgress: Double = 0

    let audioService: AudioPlayerService
    private var cancellables = Set<AnyCancellable>()
    private var downloadTask: Task<Void, Never>?

    init(audioService: AudioPlayerService) {
        self.audioService = audioService

        // Forward audioService changes so views that observe PlayerViewModel
        // also redraw when isPlaying, currentTime, etc. change.
        // receive(on:) defers delivery to the next run loop tick, avoiding
        // "Publishing changes from within view updates" warnings.
        audioService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Playback

    /// Opens a book for playback (loads chapters, starts playing).
    /// If the book is cloud-only, downloads it first via NSFileCoordinator.
    func openBook(_ book: Book) {
        // If already downloading this book, ignore duplicate taps
        if downloadingBookID == book.objectID { return }

        currentBook = book

        // Cloud-only: download first, then play
        if book.isCloudOnly {
            startDownloadAndPlay(book)
            return
        }

        // Local file: play immediately
        playLocalBook(book)
    }

    /// Plays a local (already-downloaded) book
    private func playLocalBook(_ book: Book) {
        // Load chapters if the book has them
        if book.hasChapters, let path = book.filePath {
            Task {
                let url = URL(fileURLWithPath: path)
                chapters = await MetadataExtractor.extractChapters(from: url)
            }
        } else {
            chapters = []
        }

        loadBookmarks(for: book)
        audioService.play(book: book)
    }

    /// Downloads a cloud-only book, re-extracts metadata, then plays it
    private func startDownloadAndPlay(_ book: Book) {
        guard let path = book.filePath else { return }
        let url = URL(fileURLWithPath: path)
        let bookID = book.objectID

        // Set download state
        downloadingBookID = bookID
        downloadProgress = 0

        // Cancel any previous download
        downloadTask?.cancel()

        downloadTask = Task {
            // Get the file's reported size for progress estimation
            let fileSize: Int64 = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0

            // Start the actual download on a background thread (NSFileCoordinator blocks)
            let downloadHandle = Task.detached(priority: .userInitiated) {
                try await FileUtils.startCloudDownload(url: url)
            }

            // Poll st_blocks every second to estimate download progress
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }

                var s = stat()
                guard stat(path, &s) == 0 else { continue }

                if s.st_blocks > 0 {
                    // File has local bytes — estimate progress from blocks
                    // Each block is 512 bytes; compare to reported file size
                    if fileSize > 0 {
                        let bytesOnDisk = Int64(s.st_blocks) * 512
                        let progress = min(Double(bytesOnDisk) / Double(fileSize), 1.0)
                        self.downloadProgress = progress
                    }

                    // Check if download is complete (blocks cover the full file)
                    let bytesOnDisk = Int64(s.st_blocks) * 512
                    if bytesOnDisk >= fileSize {
                        break
                    }
                }
            }

            // Wait for the coordinator to finish (may already be done)
            do {
                try await downloadHandle.value
            } catch {
                // Download failed or was cancelled
                if !Task.isCancelled {
                    audioService.playbackError = "Download failed: \(error.localizedDescription)"
                }
                downloadingBookID = nil
                downloadProgress = 0
                return
            }

            // Download complete
            downloadProgress = 1.0

            // Re-extract metadata now that the file bytes are local
            let metadata = await MetadataExtractor.extract(from: url)
            let context = book.managedObjectContext ?? PersistenceController.shared.container.viewContext
            book.title = metadata.title ?? book.title
            book.author = metadata.author ?? book.author
            book.genre = metadata.genre ?? book.genre
            book.year = metadata.year > 0 ? metadata.year : book.year
            book.duration = metadata.duration > 0 ? metadata.duration : book.duration
            book.coverArtData = metadata.coverArtData ?? book.coverArtData
            book.hasChapters = metadata.hasChapters
            book.metadataLoaded = true
            PersistenceController.shared.save()

            // Clear download state and play
            downloadingBookID = nil
            downloadProgress = 0
            playLocalBook(book)
        }
    }

    /// Current chapter name based on playback position
    var currentChapterName: String? {
        guard !chapters.isEmpty else { return nil }
        let time = audioService.currentTime
        if let chapter = chapters.last(where: { $0.startTime <= time }) {
            return chapter.title
        }
        return chapters.first?.title
    }

    /// Updates the current chapter index based on playback position
    func updateCurrentChapter() {
        let time = audioService.currentTime
        if let index = chapters.lastIndex(where: { $0.startTime <= time }) {
            currentChapterIndex = index
        }
    }

    /// Jumps to a specific chapter
    func goToChapter(_ chapter: ChapterInfo) {
        audioService.seek(to: chapter.startTime)
    }

    /// Next chapter
    func nextChapter() {
        let next = currentChapterIndex + 1
        guard next < chapters.count else { return }
        goToChapter(chapters[next])
    }

    /// Previous chapter (goes to start of current chapter, or previous if near the start)
    func previousChapter() {
        let time = audioService.currentTime
        let current = chapters[safe: currentChapterIndex]

        // If more than 3 seconds into the chapter, go to its start
        if let current = current, time - current.startTime > 3 {
            goToChapter(current)
        } else {
            let prev = currentChapterIndex - 1
            guard prev >= 0 else { return }
            goToChapter(chapters[prev])
        }
    }

    /// Speed display label
    var speedLabel: String {
        let rate = audioService.playbackRate
        if rate == Float(Int(rate)) {
            return "\(Int(rate))x"
        }
        return String(format: "%.2gx", rate)
    }

    // MARK: - Bookmarks

    /// Loads bookmarks for the given book from Core Data, sorted by timestamp
    func loadBookmarks(for book: Book) {
        guard let bookmarkSet = book.bookmarks as? Set<Bookmark> else {
            bookmarks = []
            return
        }
        bookmarks = bookmarkSet.sorted { $0.timestamp < $1.timestamp }
    }

    /// Adds a new bookmark at the current playback position
    func addBookmark(name: String, note: String?) {
        guard let book = currentBook else { return }
        let context = book.managedObjectContext ?? PersistenceController.shared.container.viewContext

        let bookmark = Bookmark(context: context)
        bookmark.id = UUID()
        bookmark.timestamp = audioService.currentTime
        bookmark.name = name
        bookmark.note = note
        bookmark.createdDate = Date()
        bookmark.book = book

        PersistenceController.shared.save()
        loadBookmarks(for: book)
    }

    /// Deletes a bookmark from Core Data
    func deleteBookmark(_ bookmark: Bookmark) {
        guard let book = currentBook else { return }
        let context = bookmark.managedObjectContext ?? PersistenceController.shared.container.viewContext
        context.delete(bookmark)
        PersistenceController.shared.save()
        loadBookmarks(for: book)
    }

    /// Seeks playback to a bookmark's timestamp
    func jumpToBookmark(_ bookmark: Bookmark) {
        audioService.seek(to: bookmark.timestamp)
    }
}

// Safe array indexing
extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
