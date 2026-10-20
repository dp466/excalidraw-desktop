//
//  ExcalidrawCore+SaveStream.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/06/23.
//

import Foundation

extension ExcalidrawCore {
    struct CurrentFileSaveStreamRequest: Sendable {
        var streamID: String
        var includeFiles: Bool
        var chunkSize: Int
    }

    struct CurrentFileSaveStreamResult: Sendable {
        var streamID: String
        var revision: Int?
        var elementCount: Int
        var fileCount: Int
        var documentData: Data
    }

    enum CurrentFileSaveStreamError: LocalizedError, Sendable {
        case unsupported
        case missingStreamID
        case unknownStream(String)
        case duplicateStream(String)
        case unexpectedChunkIndex(expected: Int, actual: Int)
        case invalidBase64Chunk(index: Int)
        case failed(String)
        case timedOut

        var errorDescription: String? {
            switch self {
                case .unsupported:
                    return "The Web editor does not support chunked save streams."
                case .missingStreamID:
                    return "Save stream message is missing stream id."
                case .unknownStream(let streamID):
                    return "Unknown save stream: \(streamID)."
                case .duplicateStream(let streamID):
                    return "Duplicate save stream: \(streamID)."
                case .unexpectedChunkIndex(let expected, let actual):
                    return "Unexpected save stream chunk index. Expected \(expected), got \(actual)."
                case .invalidBase64Chunk(let index):
                    return "Save stream chunk \(index) is not valid base64."
                case .failed(let message):
                    return message
                case .timedOut:
                    return "Timed out waiting for save stream."
            }
        }
    }

    final class CurrentFileSaveStreamBridge {
        private let sessionStore = CurrentFileSaveStreamSessionStore()

        /// Requests the Web editor to stream the current file snapshot back
        /// through `window.webkit.messageHandlers.excalidrawZ.postMessage`.
        ///
        /// Web-side contract:
        /// - implement `window.excalidrawZHelper.requestCurrentFileSaveStream(options)`
        /// - accept `{ streamId, chunkSize, includeFiles }`
        /// - return `{ supported: true }` after starting the stream
        /// - post `{ event: "currentFileSaveStreamStarted", data: { streamId, revision, elementCount, fileCount, totalBytes? } }`
        /// - post `{ event: "currentFileSaveStreamChunk", data: { streamId, index, base64 } }` in ascending index order
        /// - post `{ event: "currentFileSaveStreamFinished", data: { streamId, revision?, elementCount?, fileCount?, totalBytes?, sha256? } }`
        /// - on failure, post `{ event: "currentFileSaveStreamFailed", data: { streamId, message } }`
        ///
        /// The streamed bytes should be the same JSON document shape returned
        /// by direct snapshots: `{ elements, appState, files? }`.
        @MainActor
        func request(
            webView: ExcalidrawWebView,
            includeFiles: Bool,
            chunkSize: Int = 65_536,
            timeoutNanoseconds: UInt64 = 30_000_000_000
        ) async throws -> CurrentFileSaveStreamResult {
            guard !webView.isLoading else {
                throw InvalidJavaScriptResult()
            }

            let streamID = UUID().uuidString
            let request = CurrentFileSaveStreamRequest(
                streamID: streamID,
                includeFiles: includeFiles,
                chunkSize: chunkSize
            )
            try await openStream(streamID: streamID)

            do {
                let ack = try await webView.callAsyncJavaScript(
                    Self.requestScript(for: request),
                    arguments: [:],
                    contentWorld: .page
                )
                guard Self.acknowledgesSupport(ack) else {
                    sessionStore.cancel(streamID: streamID)
                    throw CurrentFileSaveStreamError.unsupported
                }
                return try await awaitStream(
                    streamID: streamID,
                    timeoutNanoseconds: timeoutNanoseconds
                )
            } catch {
                sessionStore.cancel(streamID: streamID)
                throw error
            }
        }

        func openStream(streamID: String) async throws {
            try sessionStore.register(streamID: streamID)
        }

        func awaitStream(
            streamID: String,
            timeoutNanoseconds: UInt64
        ) async throws -> CurrentFileSaveStreamResult {
            try await sessionStore.wait(streamID: streamID, timeoutNanoseconds: timeoutNanoseconds)
        }

        // Script messages arrive on the main thread in the order the editor
        // posted them. Apply them synchronously so chunks and the finish
        // marker cannot be reordered by separate tasks.
        func receiveStarted(_ payload: CurrentFileSaveStreamStartedData) {
            sessionStore.receiveStarted(payload)
        }

        func receiveChunk(_ payload: CurrentFileSaveStreamChunkData) {
            sessionStore.receiveChunk(payload)
        }

        func receiveFinished(_ payload: CurrentFileSaveStreamFinishedData) {
            sessionStore.receiveFinished(payload)
        }

        func receiveFailed(_ payload: CurrentFileSaveStreamFailedData) {
            sessionStore.receiveFailed(payload)
        }

        private static func requestScript(
            for request: CurrentFileSaveStreamRequest
        ) throws -> String {
            let options: [String: Any] = [
                "streamId": request.streamID,
                "chunkSize": request.chunkSize,
                "includeFiles": request.includeFiles
            ]
            let optionsData = try JSONSerialization.data(withJSONObject: options)
            guard let optionsJSON = String(data: optionsData, encoding: .utf8) else {
                throw JSONEncodingFailed()
            }
            return """
            const helper = window.excalidrawZHelper;
            if (!helper || typeof helper.requestCurrentFileSaveStream !== "function") {
              return { supported: false };
            }
            return await helper.requestCurrentFileSaveStream(\(optionsJSON));
            """
        }

        private static func acknowledgesSupport(_ rawValue: Any?) -> Bool {
            guard let dictionary = rawValue as? [String: Any] else {
                return true
            }
            if let supported = dictionary["supported"] as? Bool {
                return supported
            }
            if let ok = dictionary["ok"] as? Bool {
                return ok
            }
            return true
        }
    }

    private final class CurrentFileSaveStreamSessionStore: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [String: Session] = [:]

        func register(streamID: String) throws {
            lock.lock()
            defer { lock.unlock() }
            guard sessions[streamID] == nil else {
                throw CurrentFileSaveStreamError.duplicateStream(streamID)
            }
            sessions[streamID] = Session()
        }

        func cancel(streamID: String) {
            lock.lock()
            let session = sessions.removeValue(forKey: streamID)
            lock.unlock()
            session?.continuation?.resume(throwing: CancellationError())
        }

        func wait(
            streamID: String,
            timeoutNanoseconds: UInt64
        ) async throws -> CurrentFileSaveStreamResult {
            let timeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    self?.finish(
                        streamID: streamID,
                        result: .failure(CurrentFileSaveStreamError.timedOut)
                    )
                } catch {
                    return
                }
            }

            defer { timeoutTask.cancel() }

            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    guard let session = sessions[streamID] else {
                        lock.unlock()
                        continuation.resume(throwing: CurrentFileSaveStreamError.unknownStream(streamID))
                        return
                    }
                    if let completion = session.completion {
                        sessions.removeValue(forKey: streamID)
                        lock.unlock()
                        continuation.resume(with: completion)
                        return
                    }
                    session.continuation = continuation
                    lock.unlock()
                }
            } onCancel: {
                self.cancel(streamID: streamID)
            }
        }

        func receiveStarted(_ payload: CurrentFileSaveStreamStartedData) {
            guard let streamID = payload.resolvedStreamID else { return }
            lock.lock()
            defer { lock.unlock() }
            guard let session = sessions[streamID] else { return }
            session.revision = payload.revision
            session.elementCount = payload.elementCount
            session.fileCount = payload.fileCount
            session.totalBytes = payload.totalBytes
            if let totalBytes = payload.totalBytes, totalBytes > 0 {
                session.data.reserveCapacity(totalBytes)
            }
        }

        func receiveChunk(_ payload: CurrentFileSaveStreamChunkData) {
            guard let streamID = payload.resolvedStreamID else { return }

            let failure: CurrentFileSaveStreamError?
            lock.lock()
            if let session = sessions[streamID] {
                if payload.index != session.nextChunkIndex {
                    failure = .unexpectedChunkIndex(
                        expected: session.nextChunkIndex,
                        actual: payload.index
                    )
                } else if let chunk = Data(base64Encoded: payload.base64) {
                    session.data.append(chunk)
                    session.nextChunkIndex += 1
                    failure = nil
                } else {
                    failure = .invalidBase64Chunk(index: payload.index)
                }
            } else {
                failure = .unknownStream(streamID)
            }
            lock.unlock()

            if let failure {
                finish(streamID: streamID, result: .failure(failure))
            }
        }

        func receiveFinished(_ payload: CurrentFileSaveStreamFinishedData) {
            guard let streamID = payload.resolvedStreamID else { return }

            lock.lock()
            guard let session = sessions[streamID] else {
                lock.unlock()
                return
            }
            let expectedBytes = payload.totalBytes ?? session.totalBytes
            let result: Result<CurrentFileSaveStreamResult, Error>
            if let expectedBytes, expectedBytes != session.data.count {
                // A missing chunk must never become a truncated document.
                result = .failure(CurrentFileSaveStreamError.failed(
                    "Save stream ended with \(session.data.count) of \(expectedBytes) bytes."
                ))
            } else {
                result = .success(CurrentFileSaveStreamResult(
                    streamID: streamID,
                    revision: payload.revision ?? session.revision,
                    elementCount: payload.elementCount ?? session.elementCount ?? 0,
                    fileCount: payload.fileCount ?? session.fileCount ?? 0,
                    documentData: session.data
                ))
            }
            lock.unlock()

            finish(streamID: streamID, result: result)
        }

        func receiveFailed(_ payload: CurrentFileSaveStreamFailedData) {
            guard let streamID = payload.resolvedStreamID else { return }
            finish(
                streamID: streamID,
                result: .failure(
                    CurrentFileSaveStreamError.failed(payload.message ?? payload.error ?? "Save stream failed.")
                )
            )
        }

        private func finish(
            streamID: String,
            result: Result<CurrentFileSaveStreamResult, Error>
        ) {
            lock.lock()
            guard let session = sessions[streamID] else {
                lock.unlock()
                return
            }
            if let continuation = session.continuation {
                sessions.removeValue(forKey: streamID)
                lock.unlock()
                continuation.resume(with: result)
            } else {
                session.completion = result
                lock.unlock()
            }
        }

        /// A reference type so chunks append in place instead of copying the
        /// growing buffer out of and back into the dictionary.
        private final class Session {
            var data = Data()
            var nextChunkIndex = 0
            var revision: Int?
            var elementCount: Int?
            var fileCount: Int?
            var totalBytes: Int?
            var continuation: CheckedContinuation<CurrentFileSaveStreamResult, Error>?
            var completion: Result<CurrentFileSaveStreamResult, Error>?
        }
    }
}
