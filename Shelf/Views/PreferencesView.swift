import SwiftUI

/// Preferences/Settings window
struct PreferencesView: View {
    @EnvironmentObject var libraryVM: LibraryViewModel

    @State private var showManageLibraries = false

    var body: some View {
        Form {
            Section("Library") {
                HStack {
                    VStack(alignment: .leading) {
                        if let library = libraryVM.activeLibrary {
                            Text(library.displayName)
                                .font(.headline)
                            if let path = library.folderPath {
                                Text(path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Text("\(libraryVM.books.count) book\(libraryVM.books.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("No Library Selected")
                                .font(.headline)
                            Text("Add a library to get started.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer()

                    Button("Manage Libraries...") {
                        showManageLibraries = true
                    }
                }

                Button("Refresh Library Now") {
                    Task { await libraryVM.scanLibrary() }
                }
                .disabled(libraryVM.isScanning || libraryVM.activeLibrary == nil)

                if libraryVM.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }

                if let result = libraryVM.scanResult {
                    Text(result.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Backup") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Export Progress")
                            .font(.headline)
                        Text("Save your playback positions and bookmarks to a JSON file.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Export...") {
                        libraryVM.exportProgress()
                    }
                }

                HStack {
                    VStack(alignment: .leading) {
                        Text("Import Progress")
                            .font(.headline)
                        Text("Restore playback positions and bookmarks from a backup file.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Import...") {
                        libraryVM.importProgress()
                    }
                }
            }

            Section("About") {
                Text("Shelf v1.0")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("A native audiobook player for macOS.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 400)
        .sheet(isPresented: $showManageLibraries) {
            ManageLibrariesView()
                .environmentObject(libraryVM)
        }
    }
}
