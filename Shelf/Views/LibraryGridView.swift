import SwiftUI

/// Displays the book library in grid, big grid, or list mode
struct LibraryGridView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel
    @EnvironmentObject var playerVM: PlayerViewModel
    @FocusState private var isSearchFocused: Bool

    // Grid column definitions for each mode
    private var gridColumns: [GridItem] {
        switch libraryVM.viewMode {
        case .grid:
            return [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 20)]
        case .bigGrid:
            return [GridItem(.adaptive(minimum: 240, maximum: 280), spacing: 24)]
        case .list:
            return [] // not used
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar: search + view mode + sort
            toolbar

            Divider()

            // Content
            if libraryVM.isScanning {
                Spacer()
                ProgressView("Scanning library...")
                    .padding()
                Spacer()
            } else if libraryVM.filteredBooks.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                switch libraryVM.viewMode {
                case .grid:
                    gridView(size: .regular)
                case .bigGrid:
                    gridView(size: .large)
                case .list:
                    listView
                }
            }
        }
        .onAppear {
            // Don't auto-focus the search field — spacebar should control playback by default
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = false
            }
        }
        .onExitCommand {
            isSearchFocused = false
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search books...", text: $libraryVM.searchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                if !libraryVM.searchText.isEmpty {
                    Button {
                        libraryVM.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.quaternary)
            .cornerRadius(8)
            .frame(maxWidth: 300)

            Spacer()

            // Book count
            Text("\(libraryVM.filteredBooks.count) books")
                .foregroundColor(.secondary)
                .font(.caption)

            // View mode picker
            Picker("View", selection: $libraryVM.viewMode) {
                ForEach(LibraryViewModel.ViewMode.allCases, id: \.self) { mode in
                    Image(systemName: mode.icon)
                        .help(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 100)

            // Sort picker
            Menu {
                ForEach(LibraryViewModel.SortOrder.allCases, id: \.self) { order in
                    Button {
                        libraryVM.sortOrder = order
                    } label: {
                        HStack {
                            Text(order.rawValue)
                            if libraryVM.sortOrder == order {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    // MARK: - Grid View

    private func gridView(size: BookCardSize) -> some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, spacing: size == .large ? 28 : 24) {
                ForEach(libraryVM.filteredBooks, id: \.objectID) { book in
                    BookCardView(book: book, size: size) {
                        playerVM.openBook(book)
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - List View

    private var listView: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack(spacing: 12) {
                Spacer().frame(width: 40) // cover art space
                Spacer().frame(width: 14) // playing indicator space

                Text("Title")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 200, alignment: .leading)

                Spacer()

                Text("Genre")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(width: 100, alignment: .leading)

                Text("Duration")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(width: 70, alignment: .trailing)

                Text("Progress")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(width: 90, alignment: .trailing)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 28)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.03))

            Divider()

            // Rows
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(libraryVM.filteredBooks, id: \.objectID) { book in
                        BookListRow(
                            book: book,
                            onTap: { playerVM.openBook(book) },
                            isCurrentlyPlaying: playerVM.currentBook?.objectID == book.objectID
                        )
                        Divider().padding(.leading, 64)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "book.closed")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            if libraryVM.activeLibrary == nil {
                Text("No library selected")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Button("Add Library") {
                    libraryVM.addLibrary()
                }
            } else if !libraryVM.searchText.isEmpty {
                Text("No books match your search")
                    .font(.title3)
                    .foregroundColor(.secondary)
            } else {
                Text("No audiobooks found")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Text("Add m4b, m4a, or mp3 files to your audiobooks folder and refresh.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
