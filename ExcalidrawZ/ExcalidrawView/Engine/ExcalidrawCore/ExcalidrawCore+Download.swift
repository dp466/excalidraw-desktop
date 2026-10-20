//
//  WebView+Download.swift
//  ExcalidrawZ
//
//  Created by Dove Zachary on 2023/7/10.
//

import Foundation
import WebKit


extension ExcalidrawCore: WKDownloadDelegate {
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        switch suggestedFilename.components(separatedBy: ".").last {
            case .some("excalidraw"):
                return nil
                
            case .some("png"):
                return onExportPNG(download, decideDestinationUsing: response, suggestedFilename: suggestedFilename)
                
            default:
                return nil
        }
    }

    @MainActor
    func downloadDidFinish(_ download: WKDownload) {
        guard let request = download.originalRequest,
              let url = downloads[request] else { return }
        logger.info("download did finished: \(url)")
        self.parent?.exportState.finishExport(download: download)
        downloads.removeValue(forKey: request)
    }
    
    @MainActor
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let request = download.originalRequest {
            downloads.removeValue(forKey: request)
        }
        logger.warning("download failed: \(error)")
    }

    func onExportPNG(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) -> URL? {
        self.logger.info("on export png.")
        let fileManager: FileManager = FileManager.default
        do {
            let directory: URL = try getTempDirectory()
            let fileExtension = suggestedFilename.components(separatedBy: ".").last ?? "png"
            // Drawing names may contain "/" or ":", which would name a folder.
            let baseName = self.parent?.fileState.currentActiveFile?.name?
                .components(separatedBy: CharacterSet(charactersIn: "/:"))
                .joined(separator: "-")
            let fileName = baseName.flatMap { $0.isEmpty ? nil : $0 + ".\(fileExtension)" } ?? suggestedFilename
            let url = directory.appendingPathComponent(fileName, conformingTo: .image)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            
            if let request = download.originalRequest {
                self.downloads[request] = url;
            }
            
            self.parent?.exportState.beginExport(url: url, download: download)
            return url;
        } catch {
            self.parent?.onError(error)
            return nil
        }
    }
}
