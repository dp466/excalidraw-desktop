//
//  ExcalidrawPNGDecoder.swift
//  ExcalidrawZ
//
//  Created by Dove Zachary on 2024/10/10.
//

import Foundation
import Compression

import Zlib

class ExcalidrawPNGDecoder: ExcalidrawImageDecoder {
    struct PNGChunk {
        let length: UInt32
        let type: String
        let data: Data
        let crc: UInt32
    }
    
    struct TextChunk {
        var keyword: String
        var text: String
    }
    

    func decode(from imageData: Data) -> ExcalidrawFile? {
        guard !self.isValidJSON(imageData) else { return nil }
        
        guard let textChunk = findTextChunk(from: imageData) else {
            return nil
        }
        let chunk = TextChunk(keyword: textChunk.0, text: textChunk.1)
        guard chunk.keyword == "application/vnd.excalidraw+json" else {
            return nil
        }
        
        /// packages/excalidraw/data/image.ts - 47
        guard let textData = chunk.text.data(using: .utf8) else {
            return nil
        }
        do {
            guard let encodedData = try JSONSerialization.jsonObject(with: textData) as? [String : Any] else {
                return nil
            }
            
            if encodedData.keys.contains("encoded") {
                let decoded = try self.decodeEncodedData(data: textData)
                
                if let data = decoded.data(using: .utf8) {
                    return try ExcalidrawFile(data: data)
                }
                
            } else if let type = encodedData["type"] as? String, type == "excalidraw" {
                if let data = chunk.text.data(using: .utf8) {
                    return try ExcalidrawFile(data: data)
                }
            }
        } catch {
            return nil
        }
        
        if let data = chunk.text.data(using: .utf8) {
            return try? ExcalidrawFile(data: data)
        } else {
            return nil
        }
    }
}

extension ExcalidrawPNGDecoder {
    /// Files come from linked folders, drops and Quick Look: a truncated or
    /// malformed PNG must end the scan, not read past the data.
    private func parsePNGChunks(from data: Data) -> [PNGChunk] {
        let bytes = [UInt8](data)
        func uint32(at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
        }

        var chunks: [PNGChunk] = []
        var offset = 8 // 跳过 PNG 文件的前 8 个字节（文件头部）

        while offset + 8 <= bytes.count {
            guard let length = uint32(at: offset),
                  let type = String(bytes: bytes[(offset + 4)..<(offset + 8)], encoding: .ascii) else { break }
            let dataStart = offset + 8
            let (dataEnd, overflow) = dataStart.addingReportingOverflow(Int(length))
            guard !overflow, dataEnd + 4 <= bytes.count, let crc = uint32(at: dataEnd) else { break }
            chunks.append(PNGChunk(
                length: length,
                type: type,
                data: Data(bytes[dataStart..<dataEnd]),
                crc: crc
            ))
            offset = dataEnd + 4
        }

        return chunks
    }

    private func findTextChunk(from imageData: Data) -> (keyword: String, text: String)? {
        let chunks = parsePNGChunks(from: imageData)
        if let metadataChunk = chunks.first(where: {$0.type == "tEXt"}) {
            return decodeTextChunk(from: metadataChunk.data)
        }
        return nil
    }
    
    /// https://github.com/hughsk/png-chunk-text/blob/master/decode.js
    private func decodeTextChunk(from data: Data) -> (keyword: String, text: String)? {
        var naming = true
        var keyword = ""
        var text = ""
        
        for byte in data {
            if naming {
                if byte != 0 {
                    keyword.append(Character(UnicodeScalar(byte)))
                } else {
                    naming = false
                }
            } else {
                if byte != 0 {
                    text.append(Character(UnicodeScalar(byte)))
                } else {
                    return nil
                }
            }
        }
        
        return (keyword, text)
    }
    
}
