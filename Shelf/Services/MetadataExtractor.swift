import Foundation
import AVFoundation
import AppKit

/// Holds extracted metadata from an audio file before saving to Core Data
struct AudiobookMetadata {
    var title: String?
    var author: String?
    var genre: String?
    var year: Int32 = 0
    var duration: Double = 0
    var coverArtData: Data?
    var hasChapters: Bool = false
}

/// Chapter info extracted from m4b/m4a files
struct ChapterInfo: Identifiable {
    let id = UUID()
    let title: String
    let startTime: Double
    let duration: Double

    var endTime: Double { startTime + duration }
}

/// Extracts metadata from audio files using AVFoundation
enum MetadataExtractor {

    /// Extracts metadata from a file at the given URL
    static func extract(from url: URL) async -> AudiobookMetadata {
        let asset = AVURLAsset(url: url)
        var metadata = AudiobookMetadata()

        // Load duration
        do {
            let duration = try await asset.load(.duration)
            metadata.duration = CMTimeGetSeconds(duration)
        } catch {
            print("Failed to load duration for \(url.lastPathComponent): \(error)")
        }

        // Load common metadata (title, author, artwork, etc.)
        do {
            let commonMetadata = try await asset.load(.commonMetadata)

            for item in commonMetadata {
                guard let key = item.commonKey else { continue }

                switch key {
                case .commonKeyTitle:
                    metadata.title = try? await item.load(.stringValue)

                case .commonKeyArtist, .commonKeyAuthor:
                    if metadata.author == nil {
                        metadata.author = try? await item.load(.stringValue)
                    }

                case .commonKeyArtwork:
                    if let data = try? await item.load(.dataValue) {
                        metadata.coverArtData = data
                    }

                case .commonKeyCreationDate:
                    if let dateStr = try? await item.load(.stringValue),
                       let yearInt = Int32(String(dateStr.prefix(4))) {
                        metadata.year = yearInt
                    }

                default:
                    break
                }
            }
        } catch {
            print("Failed to load metadata for \(url.lastPathComponent): \(error)")
        }

        // Extract genre and year from format-specific metadata (iTunes for m4b/m4a, ID3 for mp3)
        do {
            let formats = try await asset.load(.availableMetadataFormats)
            for format in formats {
                let items = try await asset.loadMetadata(for: format)
                for item in items {
                    guard let identifier = item.identifier else { continue }

                    // Genre: iTunes ©gen (user genre) or gnre (genre ID), ID3 content type
                    if metadata.genre == nil {
                        if identifier == .iTunesMetadataUserGenre ||
                           identifier == .iTunesMetadataGenreID ||
                           identifier == .id3MetadataContentType {
                            if let val = try? await item.load(.stringValue), !val.isEmpty {
                                metadata.genre = val
                            }
                        }
                    }

                    // Year from format-specific metadata if not found in common
                    if metadata.year == 0 {
                        if identifier == .iTunesMetadataReleaseDate ||
                           identifier == .id3MetadataYear ||
                           identifier == .id3MetadataDate ||
                           identifier == .id3MetadataRecordingTime {
                            if let val = try? await item.load(.stringValue),
                               let yearInt = Int32(String(val.prefix(4))) {
                                metadata.year = yearInt
                            }
                        }
                    }
                }
            }
        } catch {
            // Non-critical — genre/year are optional
        }

        // Check for chapters
        do {
            let chapterLocales = try await asset.load(.availableChapterLocales)
            if !chapterLocales.isEmpty {
                let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages:
                    chapterLocales.map { Locale.canonicalLanguageIdentifier(from: $0.identifier) })
                metadata.hasChapters = !groups.isEmpty
            }
        } catch {
            // Non-critical — chapters are optional
        }

        return metadata
    }

    /// Extracts metadata with a timeout — returns nil if extraction takes too long.
    /// This prevents slow cloud-mounted files (e.g., Google Drive FUSE) from blocking the queue.
    static func extractWithTimeout(from url: URL, timeout: TimeInterval = 10) async -> AudiobookMetadata? {
        return await withTaskGroup(of: AudiobookMetadata?.self) { group in
            // Race: actual extraction vs. timeout
            group.addTask {
                return await Self.extract(from: url)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            // First result wins
            let result = await group.next()
            group.cancelAll()
            return result ?? nil
        }
    }

    /// Extracts chapter list from an audio file
    static func extractChapters(from url: URL) async -> [ChapterInfo] {
        let asset = AVURLAsset(url: url)
        var chapters: [ChapterInfo] = []

        do {
            let chapterLocales = try await asset.load(.availableChapterLocales)
            guard !chapterLocales.isEmpty else { return [] }

            let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages:
                chapterLocales.map { Locale.canonicalLanguageIdentifier(from: $0.identifier) })

            for group in groups {
                let timeRange = group.timeRange
                let startSeconds = CMTimeGetSeconds(timeRange.start)
                let durationSeconds = CMTimeGetSeconds(timeRange.duration)

                // Try to get chapter title
                var chapterTitle = "Chapter \(chapters.count + 1)"
                for item in group.items {
                    if item.commonKey == .commonKeyTitle,
                       let title = try? await item.load(.stringValue) {
                        chapterTitle = title
                        break
                    }
                }

                chapters.append(ChapterInfo(
                    title: chapterTitle,
                    startTime: startSeconds,
                    duration: durationSeconds
                ))
            }
        } catch {
            print("Failed to extract chapters: \(error)")
        }

        return chapters
    }
}
