//
//  AdjustElementsTool operation module.
//

import Foundation

extension AdjustElementsMiddleware {
    func applyAddOp(
        _ op: AddOp,
        elements: inout [ExcalidrawElement],
        canvasActions: inout [CanvasAction]
    ) async throws {
        let hydrated = try await hydrateImageSkeletonSources(op)
        try validateImageSkeletonFiles(
            elements: hydrated.elements,
            files: hydrated.files
        )

        let position = try op.position ?? resolvedPlacePosition(
            op.place,
            skeleton: hydrated.elements,
            existingElements: elements
        )
        canvasActions.append(.insertSkeleton(SkeletonInsertAction(
            skeletons: hydrated.elements,
            layout: op.layout,
            layoutOptions: op.layoutOptions,
            regenerateIds: op.regenerateIds,
            position: position,
            focus: op.focus,
            files: hydrated.files,
            captureUpdate: op.captureUpdate,
            sanitize: op.sanitize
        )))
    }

    fileprivate func hydrateImageSkeletonSources(_ op: AddOp) async throws -> HydratedImageSkeletons {
        var files = op.files ?? [:]
        let elements = try await op.elements.hydratingImageSkeletonSources(
            attachments: imageAttachments,
            files: &files
        )
        return HydratedImageSkeletons(
            elements: elements,
            files: files.isEmpty ? nil : files
        )
    }

    func validateImageSkeletonFiles(
        elements: ExcalidrawCore.JSONValue,
        files: [String: ExcalidrawCore.JSONValue]?
    ) throws {
        let imageFileIDs = try elements.imageSkeletonFileIDs(
            availableAttachmentIDs: imageAttachmentIDs
        )
        guard !imageFileIDs.isEmpty else { return }

        let availableFileIDs = Set(files.map { Array($0.keys) } ?? [])
        for fileID in imageFileIDs where !availableFileIDs.contains(fileID) {
            throw AdjustmentError(
                message: """
                Image skeleton fileId "\(fileID)" has no matching entry in add.files. \
                Do not invent fileIds for user-uploaded chat images. For chat attachments, \
                use source { "kind": "attachment", "id": "input_image_1" } and let the tool \
                create the Excalidraw fileId. Available attachment ids: \(imageAttachmentIDList).
                """
            )
        }
    }

    var imageAttachmentIDs: Set<String> {
        Set(imageAttachments.map(\.id))
    }

    var imageAttachmentIDList: String {
        let ids = imageAttachments.map(\.id).sorted()
        return ids.isEmpty ? "none" : ids.joined(separator: ", ")
    }

    func resolvedPlacePosition(
        _ place: PlaceHint?,
        skeleton: ExcalidrawCore.JSONValue,
        existingElements: [ExcalidrawElement]
    ) throws -> ExcalidrawCore.MermaidPosition? {
        guard let place else { return nil }
        guard let anchor = existingElements.first(where: { $0.id == place.relativeToId }) else {
            throw AdjustmentError(message: "place.relativeToId \(place.relativeToId) not found.")
        }

        let gap = place.gap ?? 40
        let width = skeleton.numberValue(forKey: "width") ?? 160
        let height = skeleton.numberValue(forKey: "height") ?? 100
        let point: ExcalidrawCore.MermaidPointPosition

        switch place.position {
            case "right":
                point = .init(x: anchor.x + anchor.width + gap, y: anchor.y, anchor: .topLeft)
            case "left":
                point = .init(x: anchor.x - width - gap, y: anchor.y, anchor: .topLeft)
            case "above":
                point = .init(x: anchor.x, y: anchor.y - height - gap, anchor: .topLeft)
            case "inside":
                point = .init(x: anchor.x + gap, y: anchor.y + gap, anchor: .topLeft)
            case "below":
                fallthrough
            default:
                point = .init(x: anchor.x, y: anchor.y + anchor.height + gap, anchor: .topLeft)
        }

        return .point(point)
    }
}

private struct HydratedImageSkeletons {
    let elements: ExcalidrawCore.JSONValue
    let files: [String: ExcalidrawCore.JSONValue]?
}

private extension ExcalidrawCore.JSONValue {
    func numberValue(forKey key: String) -> Double? {
        guard case .object(let object) = self,
              case .number(let value)? = object[key] else {
            return nil
        }
        return value
    }

    func imageSkeletonFileIDs(
        availableAttachmentIDs: Set<String>
    ) throws -> [String] {
        var result: [String] = []
        try collectImageSkeletonFileIDs(
            availableAttachmentIDs: availableAttachmentIDs,
            into: &result
        )
        return result
    }

    func collectImageSkeletonFileIDs(
        availableAttachmentIDs: Set<String>,
        into result: inout [String]
    ) throws {
        switch self {
            case .array(let values):
                for value in values {
                    try value.collectImageSkeletonFileIDs(
                        availableAttachmentIDs: availableAttachmentIDs,
                        into: &result
                    )
                }

            case .object(let object):
                if case .string("image")? = object["type"] {
                    guard case .string(let fileID)? = object["fileId"],
                          !fileID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else {
                        let ids = availableAttachmentIDs.sorted()
                        let idList = ids.isEmpty ? "none" : ids.joined(separator: ", ")
                        throw AdjustElementsMiddleware.AdjustmentError(
                            message: """
                            Image skeletons must include either a hydrated fileId with a matching \
                            add.files entry, or source { "kind": "attachment", "id": \
                            "input_image_1" } for a chat attachment. Available attachment ids: \
                            \(idList). Do not invent fileIds.
                            """
                        )
                    }
                    result.append(fileID)
                }

                for value in object.values {
                    try value.collectImageSkeletonFileIDs(
                        availableAttachmentIDs: availableAttachmentIDs,
                        into: &result
                    )
                }

            default:
                break
        }
    }

    func hydratingImageSkeletonSources(
        attachments: [AIChatImageAttachmentReference],
        files: inout [String: ExcalidrawCore.JSONValue]
    ) async throws -> ExcalidrawCore.JSONValue {
        switch self {
            case .array(let values):
                var hydrated: [ExcalidrawCore.JSONValue] = []
                hydrated.reserveCapacity(values.count)
                for value in values {
                    let next = try await value.hydratingImageSkeletonSources(
                        attachments: attachments,
                        files: &files
                    )
                    hydrated.append(next)
                }
                return .array(hydrated)

            case .object(let object):
                if case .string("image")? = object["type"] {
                    let hydratedObject = try await hydrateImageSkeletonObject(
                        object,
                        attachments: attachments,
                        files: &files
                    )
                    return .object(hydratedObject)
                }
                var hydrated: [String: ExcalidrawCore.JSONValue] = [:]
                hydrated.reserveCapacity(object.count)
                for (key, value) in object {
                    let next = try await value.hydratingImageSkeletonSources(
                        attachments: attachments,
                        files: &files
                    )
                    hydrated[key] = next
                }
                return .object(hydrated)

            default:
                return self
        }
    }

    func hydrateImageSkeletonObject(
        _ object: [String: ExcalidrawCore.JSONValue],
        attachments: [AIChatImageAttachmentReference],
        files: inout [String: ExcalidrawCore.JSONValue]
    ) async throws -> [String: ExcalidrawCore.JSONValue] {
        guard let source = try ImageSkeletonSource(object: object) else {
            return object
        }

        let resource = try await source.resourceFile(attachments: attachments)
        var hydrated = object
        let fileID = uniqueFileID(existingIDs: Set(files.keys))
        let resourceFile = ExcalidrawFile.ResourceFile(
            mimeType: resource.mimeType,
            id: fileID,
            createdAt: Date(),
            dataURL: resource.dataURL,
            lastRetrievedAt: Date()
        )
        hydrated["fileId"] = .string(fileID)
        hydrated["source"] = nil
        hydrated["attachmentId"] = nil
        hydrated["dataURL"] = nil
        hydrated["base64"] = nil
        hydrated["mimeType"] = nil
        hydrated["url"] = nil
        hydrated["filePath"] = nil
        hydrated["path"] = nil
        files[fileID] = resourceFile.jsonValue
        return hydrated
    }

    func uniqueFileID(existingIDs: Set<String>) -> String {
        var id = ExcalidrawNanoID.make()
        while existingIDs.contains(id) {
            id = ExcalidrawNanoID.make()
        }
        return id
    }
}

private struct ImageSkeletonSource {
    private enum Kind {
        case attachment(String)
        case dataURL(String)
        case base64(data: String, mimeType: String)
        case url(String)
        case unsupported(kind: String, detail: String?)
    }

    private let kind: Kind

    init?(object: [String: ExcalidrawCore.JSONValue]) throws {
        if case .object(let source)? = object["source"] {
            self.kind = try Self.kind(fromSourceObject: source)
            return
        }
        if let attachmentID = object.stringValue(forKey: "attachmentId") {
            self.kind = .attachment(attachmentID)
            return
        }
        if let dataURL = object.stringValue(forKey: "dataURL") {
            self.kind = .dataURL(dataURL)
            return
        }
        if let base64 = object.stringValue(forKey: "base64") {
            self.kind = .base64(
                data: base64,
                mimeType: object.stringValue(forKey: "mimeType") ?? "image/png"
            )
            return
        }
        if let url = object.stringValue(forKey: "url") {
            self.kind = url.lowercased().hasPrefix("data:")
                ? .dataURL(url)
                : .url(url)
            return
        }
        if let path = object.stringValue(forKey: "filePath") ?? object.stringValue(forKey: "path") {
            self.kind = .unsupported(kind: "filePath", detail: path)
            return
        }
        return nil
    }

    func resourceFile(
        attachments: [AIChatImageAttachmentReference]
    ) async throws -> (mimeType: String, dataURL: String) {
        switch kind {
            case .attachment(let id):
                guard let attachment = attachments.first(where: { $0.id == id }) else {
                    throw AdjustElementsMiddleware.AdjustmentError(
                        message: """
                        Image attachment source "\(id)" was not found. Use one of the available \
                        chat attachment ids: \(Self.availableAttachmentIDs(attachments)). If no \
                        attachment id is available, ask the user to attach the image instead of \
                        inventing a fileId.
                        """
                    )
                }
                return (attachment.mimeType, attachment.dataURL)

            case .dataURL(let dataURL):
                guard let parsed = AIChatImageAttachmentReference.parseDataURL(dataURL),
                      parsed.mimeType.lowercased().hasPrefix("image/")
                else {
                    throw AdjustElementsMiddleware.AdjustmentError(
                        message: """
                        Image dataURL source is invalid. Provide a complete image data URL such as \
                        data:image/png;base64,..., or use source { "kind": "attachment", \
                        "id": "input_image_1" } or source { "kind": "url", "url": "https://..." }.
                        """
                    )
                }
                return (parsed.mimeType, dataURL)

            case .base64(let data, let mimeType):
                guard mimeType.lowercased().hasPrefix("image/"),
                      let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters)
                else {
                    throw AdjustElementsMiddleware.AdjustmentError(
                        message: """
                        Image base64 source is invalid. Provide raw base64 image bytes with an \
                        image/* mimeType, or use source { "kind": "attachment", \
                        "id": "input_image_1" } or source { "kind": "url", "url": "https://..." }.
                        """
                    )
                }
                return (
                    mimeType,
                    AIChatImageAttachmentReference.makeDataURL(
                        data: decoded,
                        mimeType: mimeType
                    )
                )

            case .url(let url):
                return try await ImageURLResourceLoader.load(url)

            case .unsupported(let kind, let detail):
                let suffix = detail.map { " Received: \($0)" } ?? ""
                throw AdjustElementsMiddleware.AdjustmentError(
                    message: """
                    Image source kind "\(kind)" is not supported by adjust_elements. Use a chat \
                    attachment source instead: { "kind": "attachment", "id": "input_image_1" }, \
                    provide inline dataURL/base64 image data, or use an HTTPS image URL.\(suffix)
                    """
                )
        }
    }

    private static func kind(
        fromSourceObject object: [String: ExcalidrawCore.JSONValue]
    ) throws -> Kind {
        let kind = object.stringValue(forKey: "kind") ?? object.stringValue(forKey: "type")
        switch kind?.lowercased() {
            case "attachment", "chat_attachment", "input_image":
                guard let id = object.stringValue(forKey: "id") ?? object.stringValue(forKey: "attachmentId") else {
                    throw AdjustElementsMiddleware.AdjustmentError(
                        message: """
                        Image attachment source must include an id, for example \
                        { "kind": "attachment", "id": "input_image_1" }.
                        """
                    )
                }
                return .attachment(id)

            case "dataurl", "data_url":
                guard let dataURL = object.stringValue(forKey: "dataURL") ?? object.stringValue(forKey: "url") else {
                    throw AdjustElementsMiddleware.AdjustmentError(
                        message: "Image dataURL source must include dataURL."
                    )
                }
                return .dataURL(dataURL)

            case "base64":
                guard let data = object.stringValue(forKey: "data") ?? object.stringValue(forKey: "base64") else {
                    throw AdjustElementsMiddleware.AdjustmentError(
                        message: "Image base64 source must include data or base64."
                    )
                }
                return .base64(
                    data: data,
                    mimeType: object.stringValue(forKey: "mimeType") ?? "image/png"
                )

            case "url":
                guard let url = object.stringValue(forKey: "url") else {
                    return .unsupported(kind: "url", detail: nil)
                }
                return url.lowercased().hasPrefix("data:")
                    ? .dataURL(url)
                    : .url(url)

            case "file", "file_path", "filepath", "path":
                return .unsupported(
                    kind: "filePath",
                    detail: object.stringValue(forKey: "path") ?? object.stringValue(forKey: "filePath")
                )

            case .some(let value):
                throw AdjustElementsMiddleware.AdjustmentError(
                    message: """
                    Unsupported image source kind "\(value)". Use "attachment", "dataURL", "base64", or "url".
                    """
                )

            case .none:
                if let id = object.stringValue(forKey: "id") {
                    return .attachment(id)
                }
                throw AdjustElementsMiddleware.AdjustmentError(
                    message: """
                    Image source must include kind. Preferred form: \
                    { "kind": "attachment", "id": "input_image_1" }.
                    """
                )
        }
    }

    private static func availableAttachmentIDs(
        _ attachments: [AIChatImageAttachmentReference]
    ) -> String {
        let ids = attachments.map(\.id).sorted()
        return ids.isEmpty ? "none" : ids.joined(separator: ", ")
    }
}

private enum ImageURLResourceLoader {
    private static let maxBytes = 12 * 1024 * 1024
    private static let acceptHeader = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8"
    private static let acceptLanguageHeader = "en-US,en;q=0.9"
    private static let userAgentHeader = """
    Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) \
    AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15
    """

    static func load(_ rawURL: String) async throws -> (mimeType: String, dataURL: String) {
        // validatedURL resolves the host (blocking DNS); keep it off the
        // cooperative pool.
        let url = try await Task.detached(priority: .userInitiated) {
            try validatedURL(rawURL)
        }.value
        let referer = sameOriginReferer(for: url)
        let request = makeRequest(url: url, referer: referer)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 2

        let result: PublicNetworkFetchResult
        do {
            result = try await PublicNetworkFetcher.fetch(
                request,
                configuration: configuration,
                maxBytes: maxBytes,
                truncatesOverflow: false,
                redirect: { redirected in
                    guard let target = redirected.url else {
                        throw AdjustElementsMiddleware.AdjustmentError(
                            message: "Image URL redirect target is invalid. Use a direct public HTTPS image URL."
                        )
                    }
                    var allowed = makeRequest(url: try validatedURL(target.absoluteString), referer: referer)
                    allowed.httpMethod = redirected.httpMethod
                    return allowed
                }
            )
        } catch let error as AdjustElementsMiddleware.AdjustmentError {
            throw error
        } catch PublicNetworkFetchError.tooLarge {
            throw AdjustElementsMiddleware.AdjustmentError(
                message: """
                Image URL is too large. Maximum is \(maxBytes) bytes. Use a smaller image \
                or attach a compressed version.
                """
            )
        } catch let error as PublicNetworkFetchError {
            throw AdjustElementsMiddleware.AdjustmentError(
                message: """
                \(error.localizedDescription) Use a public HTTPS image URL, or attach the image \
                and reference input_image_1.
                """
            )
        } catch {
            throw AdjustElementsMiddleware.AdjustmentError(
                message: """
                Failed to fetch image URL "\(rawURL)": \(error.localizedDescription). Use a reachable \
                HTTPS image URL, or attach the image and reference input_image_1.
                """
            )
        }

        let httpResponse = result.response
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AdjustElementsMiddleware.AdjustmentError(
                message: """
                Image URL returned HTTP \(httpResponse.statusCode). Some websites block direct image \
                downloads or hotlinking. Use a direct public HTTPS image URL, or attach the image \
                and reference input_image_1.
                """
            )
        }

        let mimeType = (httpResponse.mimeType ?? "application/octet-stream").lowercased()
        guard mimeType.hasPrefix("image/") else {
            throw AdjustElementsMiddleware.AdjustmentError(
                message: """
                Image URL must return an image/* MIME type. Received "\(mimeType)". Use a direct \
                image URL, or attach the image and reference input_image_1.
                """
            )
        }

        let data = result.data
        guard !data.isEmpty else {
            throw AdjustElementsMiddleware.AdjustmentError(
                message: "Image URL returned an empty response. Use a direct HTTPS image URL."
            )
        }
        return (
            mimeType,
            AIChatImageAttachmentReference.makeDataURL(data: data, mimeType: mimeType)
        )
    }

    private static func makeRequest(url: URL, referer: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(acceptHeader, forHTTPHeaderField: "Accept")
        request.setValue(acceptLanguageHeader, forHTTPHeaderField: "Accept-Language")
        request.setValue(userAgentHeader, forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        return request
    }

    private static func sameOriginReferer(for url: URL) -> String? {
        guard let scheme = url.scheme,
              let host = url.host else {
            return nil
        }

        let port: String
        if let urlPort = url.port {
            port = ":\(urlPort)"
        } else {
            port = ""
        }
        return "\(scheme)://\(host)\(port)/"
    }

    private static func validatedURL(_ rawURL: String) throws -> URL {
        guard let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = components.url
        else {
            throw AdjustElementsMiddleware.AdjustmentError(
                message: """
                Image URL source must be an absolute HTTPS URL. Use \
                { "kind": "url", "url": "https://example.com/image.png" }.
                """
            )
        }
        guard components.user == nil, components.password == nil else {
            throw AdjustElementsMiddleware.AdjustmentError(
                message: "Image URL source must not include credentials."
            )
        }
        guard PublicNetworkHostPolicy.isPublicDestination(host) else {
            throw AdjustElementsMiddleware.AdjustmentError(
                message: """
                Image URL host "\(host)" is local or private. Use a public HTTPS image URL, or \
                attach the image and reference input_image_1.
                """
            )
        }
        return url
    }

}

private extension Dictionary where Key == String, Value == ExcalidrawCore.JSONValue {
    func stringValue(forKey key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension ExcalidrawFile.ResourceFile {
    var jsonValue: ExcalidrawCore.JSONValue {
        var object: [String: ExcalidrawCore.JSONValue] = [
            "mimeType": .string(mimeType),
            "id": .string(id),
            "dataURL": .string(dataURL)
        ]
        if let createdAt {
            object["created"] = .number(createdAt.timeIntervalSince1970 * 1000)
        }
        if let lastRetrievedAt {
            object["lastRetrieved"] = .number(lastRetrievedAt.timeIntervalSince1970 * 1000)
        }
        return .object(object)
    }
}

/// Hosts AI-driven fetches must not reach: loopback, link-local, private
/// and multicast ranges (the app's own loopback servers, LAN devices).
enum PublicNetworkHostPolicy {
    static func isBlockedHost(_ host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !normalized.isEmpty else { return true }
        if normalized == "localhost" ||
            normalized.hasSuffix(".localhost") ||
            normalized.hasSuffix(".local") {
            return true
        }
        if let ipv4 = parseIPv4(normalized) {
            return isBlockedIPv4(ipv4)
        }
        if normalized.contains(":") {
            if normalized == "::" ||
                normalized == "::1" ||
                normalized.hasPrefix("fe80:") ||
                normalized.hasPrefix("fc") ||
                normalized.hasPrefix("fd") ||
                normalized.hasPrefix("ff") {
                return true
            }
            if let ipv4Tail = normalized.split(separator: ":").last,
               let ipv4 = parseIPv4(String(ipv4Tail)) {
                return isBlockedIPv4(ipv4)
            }
        }
        return false
    }

    /// Name check plus DNS: a host is public only if every address it
    /// resolves to is public. Resolution also canonicalizes numeric forms
    /// ("127.1", "2130706433", "0x7f.0.0.1") that the name check does not
    /// parse. Blocking (getaddrinfo): call off the main thread.
    static func isPublicDestination(_ host: String) -> Bool {
        guard !isBlockedHost(host), !isAmbiguousNumericHost(host) else { return false }
        let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &result) == 0, let first = result else {
            return false
        }
        defer { freeaddrinfo(first) }
        var sawAddress = false
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let address = numericAddress(info.pointee.ai_addr, length: info.pointee.ai_addrlen) {
                sawAddress = true
                if isBlockedHost(address) { return false }
            }
            cursor = info.pointee.ai_next
        }
        return sawAddress
    }

    /// Numeric IPv4 written in anything but canonical dotted-decimal
    /// ("0177.0.0.1", "0x7f.1", "2130706433", "10.1"). Parsers disagree on
    /// leading zeros (octal or decimal), so such hosts are refused.
    private static func isAmbiguousNumericHost(_ host: String) -> Bool {
        let labels = host.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .split(separator: ".", omittingEmptySubsequences: false)
        let isNumericLabel: (Substring) -> Bool = { label in
            if label.hasPrefix("0x") {
                return label.dropFirst(2).allSatisfy(\.isHexDigit)
            }
            return !label.isEmpty && label.allSatisfy(\.isASCII) && label.allSatisfy(\.isNumber)
        }
        guard !labels.isEmpty, labels.allSatisfy(isNumericLabel) else { return false }
        let isCanonicalQuad = labels.count == 4 && labels.allSatisfy { label in
            !label.hasPrefix("0x") && (label == "0" || !label.hasPrefix("0")) && UInt8(label) != nil
        }
        return !isCanonicalQuad
    }

    static func isPublicDestinationAsync(_ host: String) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            isPublicDestination(host)
        }.value
    }

    private static func numericAddress(
        _ address: UnsafeMutablePointer<sockaddr>?,
        length: socklen_t
    ) -> String? {
        guard let address else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST
        ) == 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    private static func parseIPv4(_ value: String) -> [UInt8]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            octets.append(byte)
        }
        return octets
    }

    private static func isBlockedIPv4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return true }
        let first = octets[0]
        let second = octets[1]
        switch first {
            case 0, 10, 127:
                return true
            case 100:
                return (64...127).contains(second)
            case 169:
                return second == 254
            case 172:
                return (16...31).contains(second)
            case 192:
                return second == 168 || second == 0
            case 198:
                return second == 18 || second == 19 || second == 51
            case 203:
                return second == 0
            case 224...255:
                return true
            default:
                return false
        }
    }
}

enum PublicNetworkFetchError: LocalizedError, Equatable {
    case redirectRefused
    case nonPublicAddress
    case unverifiedAddress
    case tooLarge(limit: Int)

    var errorDescription: String? {
        switch self {
            case .redirectRefused:
                return "The URL redirected to a local or private address."
            case .nonPublicAddress:
                return "The URL connected to a local or private address."
            case .unverifiedAddress:
                return "The address the URL connected to could not be verified."
            case .tooLarge(let limit):
                return "The response is larger than \(limit) bytes."
        }
    }
}

struct PublicNetworkFetchResult {
    let data: Data
    let response: HTTPURLResponse
    let isTruncated: Bool
}

/// Fetches content that is handed to the model or imported, and returns it
/// only if every connection reached a public address. Callers check the host
/// name first; each redirect is checked before it is followed; and the
/// address actually connected to (URLSessionTaskMetrics) is checked before
/// anything is returned, which covers DNS rebinding between the check and
/// the connection. A rebound request may still be sent, but its response is
/// dropped. Connections through a configured proxy cannot be verified this
/// way and are trusted to the proxy.
final class PublicNetworkFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias RedirectHandler = @Sendable (URLRequest) throws -> URLRequest

    @Sendable
    static func defaultRedirect(_ request: URLRequest) throws -> URLRequest {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              PublicNetworkHostPolicy.isPublicDestination(host) else {
            throw PublicNetworkFetchError.redirectRefused
        }
        return request
    }

    static func fetch(
        _ request: URLRequest,
        configuration: URLSessionConfiguration = .ephemeral,
        maxBytes: Int,
        truncatesOverflow: Bool,
        redirect: @escaping RedirectHandler = PublicNetworkFetcher.defaultRedirect
    ) async throws -> PublicNetworkFetchResult {
        let fetcher = PublicNetworkFetcher(
            maxBytes: maxBytes,
            truncatesOverflow: truncatesOverflow,
            redirect: redirect
        )
        let session = URLSession(configuration: configuration, delegate: fetcher, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                fetcher.start(request, in: session, continuation: continuation)
            }
        } onCancel: {
            fetcher.cancel()
        }
    }

    private struct Transaction {
        let address: String?
        let isProxied: Bool
    }

    private let maxBytes: Int
    private let truncatesOverflow: Bool
    private let redirect: RedirectHandler
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PublicNetworkFetchResult, Error>?
    private var task: URLSessionDataTask?
    private var data = Data()
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var isTruncated = false
    private var stoppedEarly = false
    private var transactions: [Transaction]?
    private var completion: Error??
    private var metricsTimedOut = false

    private init(maxBytes: Int, truncatesOverflow: Bool, redirect: @escaping RedirectHandler) {
        self.maxBytes = maxBytes
        self.truncatesOverflow = truncatesOverflow
        self.redirect = redirect
    }

    private func start(
        _ request: URLRequest,
        in session: URLSession,
        continuation: CheckedContinuation<PublicNetworkFetchResult, Error>
    ) {
        let task = session.dataTask(with: request)
        lock.lock()
        self.continuation = continuation
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        do {
            completionHandler(try redirect(request))
        } catch {
            lock.lock()
            failure = error
            lock.unlock()
            completionHandler(nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let http = response as? HTTPURLResponse
        lock.lock()
        self.response = http
        let isTooLarge = !truncatesOverflow && (http?.expectedContentLength ?? 0) > Int64(maxBytes)
        if isTooLarge {
            failure = PublicNetworkFetchError.tooLarge(limit: maxBytes)
            stoppedEarly = true
        }
        lock.unlock()
        completionHandler(isTooLarge ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        var stop = false
        if data.count + chunk.count > maxBytes {
            if truncatesOverflow {
                data.append(chunk.prefix(maxBytes - data.count))
                isTruncated = true
            } else {
                failure = PublicNetworkFetchError.tooLarge(limit: maxBytes)
            }
            stoppedEarly = true
            stop = true
        } else {
            data.append(chunk)
        }
        lock.unlock()
        if stop { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let loads = metrics.transactionMetrics
            .filter { $0.resourceFetchType == .networkLoad }
            .map { Transaction(address: $0.remoteAddress, isProxied: $0.isProxyConnection) }
        lock.lock()
        transactions = loads
        lock.unlock()
        finishIfReady()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        completion = .some(error)
        let needsMetricsFallback = transactions == nil
        lock.unlock()
        if needsMetricsFallback {
            // Metrics normally arrive first; never wait on them forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
                lock.lock()
                metricsTimedOut = true
                lock.unlock()
                finishIfReady()
            }
        }
        finishIfReady()
    }

    private func finishIfReady() {
        lock.lock()
        guard let completion,
              transactions != nil || metricsTimedOut,
              let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let outcome = makeOutcome(completionError: completion)
        lock.unlock()
        continuation.resume(with: outcome)
    }

    /// Called with `lock` held.
    private func makeOutcome(completionError: Error?) -> Result<PublicNetworkFetchResult, Error> {
        if let failure { return .failure(failure) }
        if let completionError, !stoppedEarly { return .failure(completionError) }
        guard let transactions, !transactions.isEmpty else {
            return .failure(PublicNetworkFetchError.unverifiedAddress)
        }
        for transaction in transactions where !transaction.isProxied {
            guard let address = transaction.address else {
                return .failure(PublicNetworkFetchError.unverifiedAddress)
            }
            if PublicNetworkHostPolicy.isBlockedHost(address) {
                return .failure(PublicNetworkFetchError.nonPublicAddress)
            }
        }
        guard let response else { return .failure(Foundation.URLError(.badServerResponse)) }
        return .success(PublicNetworkFetchResult(data: data, response: response, isTruncated: isTruncated))
    }
}
