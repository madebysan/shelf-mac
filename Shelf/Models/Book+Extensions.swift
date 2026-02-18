import Foundation
import AppKit
import CoreData

// Convenience accessors for the Core Data Book entity
extension Book {

    // MARK: - Cover Art

    /// Returns an NSImage from the stored cover art data, or a placeholder
    var coverImage: NSImage {
        if let data = coverArtData, let image = NSImage(data: data) {
            return image
        }
        return Self.placeholderCover
    }

    /// Cached placeholder image — drawn once, reused for all books without cover art
    private static let _cachedPlaceholder: NSImage = {
        let size = NSSize(width: 200, height: 200)
        let image = NSImage(size: size)
        image.lockFocus()

        // Background
        NSColor.secondarySystemFill.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 8, yRadius: 8).fill()

        // Book icon using SF Symbol
        if let symbol = NSImage(systemSymbolName: "book.closed.fill", accessibilityDescription: "Book") {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 48, weight: .light)
            let configured = symbol.withSymbolConfiguration(symbolConfig) ?? symbol
            let symbolSize = configured.size
            let x = (size.width - symbolSize.width) / 2
            let y = (size.height - symbolSize.height) / 2
            NSColor.tertiaryLabelColor.setFill()
            configured.draw(in: NSRect(x: x, y: y, width: symbolSize.width, height: symbolSize.height))
        }

        image.unlockFocus()
        return image
    }()

    /// A simple programmatic placeholder for books without cover art (1:1)
    static var placeholderCover: NSImage { _cachedPlaceholder }

    // MARK: - Computed Properties

    /// Progress as a value between 0 and 1
    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(playbackPosition / duration, 1.0)
    }

    /// True if the book has any listening progress but isn't marked completed
    var isInProgress: Bool {
        playbackPosition > 0 && !isCompleted
    }

    /// Formatted duration string (e.g., "12h 34m")
    var formattedDuration: String {
        Self.formatTime(duration)
    }

    /// Formatted current position string
    var formattedPosition: String {
        Self.formatTime(playbackPosition)
    }

    /// Formatted remaining time
    var formattedRemaining: String {
        let remaining = max(duration - playbackPosition, 0)
        return "-" + Self.formatTime(remaining)
    }

    /// Progress as a percentage string
    var progressPercentage: String {
        let pct = Int(progress * 100)
        return "\(pct)%"
    }

    /// Display title (falls back to filename if no metadata title)
    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        // Extract filename without extension from the path
        let url = URL(fileURLWithPath: filePath ?? "")
        return url.deletingPathExtension().lastPathComponent
    }

    /// Display author (falls back to "Unknown Author")
    var displayAuthor: String {
        if let a = author, !a.isEmpty { return a }
        return "Unknown Author"
    }

    /// Display genre (falls back to "Uncategorized")
    var displayGenre: String {
        if let g = genre, !g.isEmpty { return g }
        return "Uncategorized"
    }

    // MARK: - Helpers

    /// Formats seconds into a readable time string
    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%dh %02dm", hours, minutes)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    /// Formats seconds into a scrubber-style time string (h:mm:ss or m:ss)
    static func formatScrubberTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}
