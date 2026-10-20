//
//  WebFetchTool.swift
//  AIppo
//
//  Created by Chocoford on 11/18/25.
//

import Foundation
import LLMCore

struct WebFetchTool: Tool {
    var name: String { "web_fetch" }

    var displayName: String { String(localizable: .aiChatToolWebFetchName) }

    var description: String {
        "Fetch and retrieve content from a specific URL. Use this when you have an exact URL to access."
    }

    var inputSchema: ToolInputSchema {
        .parameters(ToolParameters(
            properties: [
                "url": ParameterProperty(
                    type: "string",
                    description: "The exact URL to fetch content from"
                )
            ],
            required: ["url"]
        ))
    }

    func execute(_ input: String, context: (any ChatInvocationContext)?) async throws -> ToolResult {
        try AIChatToolExecutionGate.ensureAIEnabled()

        guard let inputData = input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: inputData) as? [String: Any],
              let urlString = json["url"] as? String,
              let url = URL(string: urlString) else {
            throw ToolError.invalidInput("Invalid URL parameter")
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw ToolError.invalidInput("Only HTTP and HTTPS URLs can be fetched.")
        }
        // Model-chosen URLs (possibly prompt-injected) must not reach the
        // app's own loopback servers or devices on the local network.
        guard let host = url.host,
              await PublicNetworkHostPolicy.isPublicDestinationAsync(host) else {
            throw ToolError.invalidInput("Only public internet URLs can be fetched.")
        }

        // Create URLRequest with proper headers
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10.0

        do {
            // Redirects and the address actually connected to are checked
            // before any content comes back. Only 2,000 characters are
            // returned, so stop reading after 2 MB.
            let result: PublicNetworkFetchResult
            do {
                result = try await PublicNetworkFetcher.fetch(
                    request,
                    maxBytes: 2 * 1024 * 1024,
                    truncatesOverflow: true
                )
            } catch let error as PublicNetworkFetchError {
                throw ToolError.executionFailed("Failed to fetch URL: \(error.localizedDescription)")
            }
            guard (200...299).contains(result.response.statusCode) else {
                throw ToolError.executionFailed("Failed to fetch URL: Invalid response")
            }
            let responseData = result.data

            guard let content = String(data: responseData, encoding: .utf8)
                    ?? String(decoding: responseData, as: UTF8.self) as String? else {
                throw ToolError.executionFailed("Failed to decode URL content")
            }

            // Strip HTML tags for better readability
            let stripped = content
                .replacingOccurrences(of: "<[^>]+>", with: "", options: [.regularExpression])
                .replacingOccurrences(of: "\\s+", with: " ", options: [.regularExpression])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

            // Limit content length
            let maxLength = 2000
            if stripped.count > maxLength {
                return .text(String(stripped.prefix(maxLength)) + "...")
            }

            return .text(stripped)
        } catch let error as ToolError {
            throw error
        } catch {
            throw ToolError.executionFailed("Failed to fetch URL: \(error.localizedDescription)")
        }
    }
}
