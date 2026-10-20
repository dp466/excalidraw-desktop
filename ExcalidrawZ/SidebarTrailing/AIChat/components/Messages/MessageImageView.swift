//
//  MessageImageView.swift
//  ExcalidrawZ
//
//  Created by Chocoford on 5/4/26.
//

import SwiftUI
import LLMCore
import ChocofordEssentials
import ImageIO

/// Inline thumbnail for an attachment on a chat message — used both by user
/// bubbles and tool-result cards (e.g. canvas screenshot tool). Decodes off
/// the main thread to keep scroll smooth.
struct MessageImageView: View {
    var file: ChatMessageContent.File

    @State private var image: Image?

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 200, maxHeight: 200)
                    .cornerRadius(8)
            }
        }
        .onAppear {
            loadImage()
        }
    }

    private func loadImage() {
        guard image == nil else { return }
        let file = file
        Task.detached(priority: .userInitiated) {
            let data: Data?
            switch file {
                case .base64EncodedImage(let base64):
                    data = base64.components(separatedBy: ",").last
                        .flatMap { Data(base64Encoded: $0) }
                case .image(let url):
                    data = try? Data(contentsOf: url)
            }
            // Decode at display size (200pt, up to 3x) instead of full
            // resolution: canvas screenshots would otherwise keep tens of
            // MB per message alive.
            guard let data, let thumbnail = Self.thumbnail(from: data, maxPixelSize: 600) else { return }
            let image = Image(platformImage: thumbnail)
            await MainActor.run {
                self.image = image
            }
        }
    }

    private static func thumbnail(from data: Data, maxPixelSize: Int) -> PlatformImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
              ] as CFDictionary) else {
            return PlatformImage(data: data)
        }
#if canImport(AppKit)
        return NSImage(cgImage: cgImage, size: .zero)
#else
        return UIImage(cgImage: cgImage)
#endif
    }
}
