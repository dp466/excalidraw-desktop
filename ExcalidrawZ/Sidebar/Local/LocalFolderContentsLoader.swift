import Foundation

enum LocalFolderContentsLoader {
    struct Metadata: Sendable, Equatable {
        let name: String
        let updatedAt: Date?
        let createdAt: Date?
    }

    struct Snapshot: Sendable, Equatable {
        let files: [URL]
        let metadata: [URL: Metadata]
    }

    static func load(
        at folderURL: URL,
        activeURL: URL?,
        sortFieldRawValue: String
    ) throws -> Snapshot? {
        guard let contents = try LocalFolder.materializedDirectoryContents(
            at: folderURL,
            includingPropertiesForKeys: [
                .nameKey,
                .contentModificationDateKey,
                .creationDateKey,
                .ubiquitousItemDownloadingStatusKey,
                .isUbiquitousItemKey,
            ],
            options: [.skipsSubdirectoryDescendants]
        ) else { return nil }

        let files = contents.compactMap { listedURL -> URL? in
            guard isSupportedFile(listedURL) else { return nil }
            if !FileManager.default.fileExists(at: listedURL) {
                let values = try? listedURL.resourceValues(
                    forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
                )
                guard values?.isUbiquitousItem == true else { return nil }
            }
            if let activeURL, listedURL.hasSameFileSystemPath(as: activeURL) {
                return activeURL
            }
            return listedURL
        }

        let metadata = Dictionary(files.map { file in
            let values = try? file.resourceValues(
                forKeys: [.contentModificationDateKey, .creationDateKey]
            )
            return (file, Metadata(
                name: file.deletingPathExtension().lastPathComponent,
                updatedAt: values?.contentModificationDate,
                createdAt: values?.creationDate
            ))
        }, uniquingKeysWith: { first, _ in first })
        let field = ExcalidrawFileSortField(rawValue: sortFieldRawValue) ?? .updatedAt
        let sortedFiles = ExcalidrawFileSortProvider.sorted(files, by: field) { file in
            let values = metadata[file]
            return ExcalidrawFileSortProvider.Values(
                name: values?.name ?? file.deletingPathExtension().lastPathComponent,
                updatedAt: values?.updatedAt,
                createdAt: values?.createdAt
            )
        }
        return Snapshot(files: sortedFiles, metadata: metadata)
    }

    static func isSupportedFile(_ url: URL) -> Bool {
        url.pathExtension == "excalidraw"
            || (url.pathExtension == "svg" && url.deletingPathExtension().pathExtension == "excalidraw")
            || (url.pathExtension == "png" && url.deletingPathExtension().pathExtension == "excalidraw")
    }
}
