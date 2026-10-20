//
//  ExcalidrawFile+Transferable.swift
//  ExcalidrawZ
//
//  Created by Dove Zachary on 2024/10/11.
//

import SwiftUI

@available(macOS 13.0, *)
extension ExcalidrawFile: Transferable {
    func fileURL() throws -> URL {
        let fileManager: FileManager = FileManager.default
        let directory: URL = try getTempDirectory()
        
        let fileExtension = "excalidraw"
        
        // "/" or ":" in a drawing name would name a missing folder, and a failed
        // createFile went unnoticed, sharing a file that did not exist.
        let baseName = (self.name ?? String(localizable: .newFileNamePlaceholder))
            .components(separatedBy: CharacterSet(charactersIn: "/:"))
            .joined(separator: "-")
        let filename = (baseName.isEmpty ? String(localizable: .newFileNamePlaceholder) : baseName) + ".\(fileExtension)"
        let url = directory.appendingPathComponent(filename, conformingTo: .fileURL)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try (self.content ?? Data()).write(to: url, options: .atomic)
        return url
    }
    
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .excalidrawFile) { file in
            SentTransferredFile(try file.fileURL(), allowAccessingOriginalFile: false)
        }
        
        DataRepresentation(exportedContentType: .excalidrawFile) { file in
            file.content ?? Data()
        }
    }
}
