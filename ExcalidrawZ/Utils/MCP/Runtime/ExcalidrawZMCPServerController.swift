//
//  ExcalidrawZMCPServerController.swift
//  ExcalidrawZ
//
//  Created by Codex on 6/15/26.
//

import Foundation
import Combine

enum ExcalidrawMCPServiceMode: String, CaseIterable, Identifiable, Sendable {
    case full
    case basic
    case optimized

    var id: Self { self }
}

@MainActor
final class ExcalidrawZMCPServerController: ObservableObject {
    enum State: Equatable {
        case off
        case starting
        case running
        case stopping
        case failed(String)
    }

    static let shared = ExcalidrawZMCPServerController()
    nonisolated static var isAvailable: Bool {
#if os(macOS)
        true
#else
        false
#endif
    }

    private static let isEnabledDefaultsKey = "ExcalidrawZMCPServerEnabled"
    private static let serviceModeDefaultsKey = "ExcalidrawZMCPServiceMode"

    @Published private(set) var state: State = .off
    @Published private(set) var isEnabled: Bool
    @Published private(set) var serviceMode: ExcalidrawMCPServiceMode
    @Published private(set) var clients: [ExcalidrawMCPClientSummary] = []
    @Published private(set) var credentialError: String?
    @Published private(set) var activeRequests: Int = 0
    @Published private(set) var activeTool: String?

    private let credentials = ExcalidrawMCPCredentialStore()

    let port: UInt16

    private var server: ExcalidrawZMCPServer?
    private var router: ExcalidrawMCPToolRouter?
    private var serverTask: Task<Void, Never>?

    private init(port: UInt16 = ExcalidrawZMCPServer.defaultPort) {
        self.port = port
        guard Self.isAvailable else {
            self.isEnabled = false
            self.serviceMode = .full
            return
        }

        self.isEnabled = UserDefaults.standard.bool(forKey: Self.isEnabledDefaultsKey)
        let loadedServiceMode = Self.loadServiceMode()
        let authorizedServiceMode = Self.authorizedServiceMode(loadedServiceMode)
        self.serviceMode = authorizedServiceMode

        if authorizedServiceMode != loadedServiceMode {
            Self.saveServiceMode(authorizedServiceMode)
        }

        // Never read the Keychain on the main thread during app launch: an unsigned
        // rebuild makes macOS ask for Keychain access, which blocked App.init (no
        // windows, quit ignored) until the prompt was answered.
        refreshClients()

        if isEnabled {
            startServerIfNeeded()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard Self.isAvailable else {
            isEnabled = false
            state = .off
            return
        }

        guard isEnabled != enabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.isEnabledDefaultsKey)

        if enabled {
            startServerIfNeeded()
        } else {
            stopServerIfNeeded()
        }
    }

    func setServiceMode(_ mode: ExcalidrawMCPServiceMode) {
        guard Self.isAvailable else {
            serviceMode = .full
            return
        }

        let authorizedMode = Self.authorizedServiceMode(mode)
        guard serviceMode != authorizedMode else {
            if authorizedMode != mode {
                Self.saveServiceMode(authorizedMode)
            }
            return
        }

        serviceMode = authorizedMode
        Self.saveServiceMode(authorizedMode)

        let router = router
        Task {
            await router?.setServiceMode(authorizedMode)
        }
    }

    func startServerIfNeeded() {
        guard Self.isAvailable else {
            state = .off
            return
        }

        guard serverTask == nil else { return }

        let router = ExcalidrawMCPToolRouter(serviceMode: serviceMode)
        let server = ExcalidrawZMCPServer(port: port, router: router, credentials: credentials) { [weak self] count, tool in
            await MainActor.run {
                self?.activeRequests = count
                self?.activeTool = tool
            }
        }
        self.server = server
        self.router = router
        state = .starting

        serverTask = Task { [weak self, server, router] in
            do {
                let rawElementConverter = ExcalidrawMCPUpstreamRawElementConverter { elements in
                    try await ExcalidrawMCPAppBridge.shared.createElements(elements)
                }

                await router.setElementConverter { elements in
                    try await rawElementConverter.convertRawElements(elements)
                }
                await router.setSessionUpdateHandler { session in
                    try await ExcalidrawMCPAppBridge.shared.apply(session)
                }

                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await server.start() }
                    group.addTask { [weak self] in
                        try await server.waitUntilListening()
                        await MainActor.run {
                            guard let self, self.isEnabled, self.state == .starting else { return }
                            self.state = .running
                        }
                    }
                    while try await group.next() != nil {}
                }

                await MainActor.run {
                    guard let self else { return }
                    self.finishServerTask(
                        unexpectedErrorMessage: "The MCP server stopped unexpectedly."
                    )
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self else { return }
                    self.finishServerTask()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.finishServerTask(unexpectedErrorMessage: error.localizedDescription)
                }
            }
        }
    }

    func stopServerIfNeeded() {
        guard let server else {
            state = .off
            return
        }

        state = .stopping
        serverTask?.cancel()
        Task { [server] in
            await server.stop()
        }
    }

    private func finishServerTask(unexpectedErrorMessage: String? = nil) {
        let wasStopping = state == .stopping
        let shouldRestart = isEnabled && wasStopping
        serverTask = nil
        server = nil
        router = nil
        activeRequests = 0
        activeTool = nil

        if shouldRestart {
            startServerIfNeeded()
        } else if !isEnabled || wasStopping {
            state = .off
        } else if let unexpectedErrorMessage {
            state = .failed(unexpectedErrorMessage)
        } else {
            state = .off
        }
    }

    private static func loadServiceMode() -> ExcalidrawMCPServiceMode {
        guard let rawValue = UserDefaults.standard.string(forKey: serviceModeDefaultsKey),
              let mode = ExcalidrawMCPServiceMode(rawValue: rawValue) else {
            return .full
        }
        return mode
    }

    private static func saveServiceMode(_ mode: ExcalidrawMCPServiceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: serviceModeDefaultsKey)
    }

    private var clientRefreshGeneration = 0

    /// Lists client summaries off the main thread and publishes the newest result.
    func refreshClients() {
        clientRefreshGeneration += 1
        let generation = clientRefreshGeneration
        let credentials = credentials
        Task.detached(priority: .utility) { [weak self] in
            let result = Result { try credentials.listClients() }
            await MainActor.run {
                guard let self, generation == self.clientRefreshGeneration else { return }
                switch result {
                    case .success(let clients):
                        self.clients = clients
                        self.credentialError = nil
                    case .failure(let error):
                        self.credentialError = error.localizedDescription
                }
            }
        }
    }

    func createClient(_ kind: ExcalidrawMCPClientKind) {
        do { try credentials.createClient(kind: kind); refreshClients() }
        catch { credentialError = error.localizedDescription }
    }

    func revokeClient(_ client: ExcalidrawMCPClientSummary) {
        do {
            try credentials.revoke(id: client.id)
            refreshClients()
            let server = server
            Task { await server?.revokeClient(client.id.uuidString) }
        } catch { credentialError = error.localizedDescription }
    }

    /// Secrets are retrieved only for an explicit copy action and never published.
    func privateConfiguration(for client: ExcalidrawMCPClientSummary) -> String? {
        do {
            guard let credential = try credentials.credential(id: client.id) else {
                credentialError = "This credential was revoked. Create a new client credential."
                return nil
            }
            return ExcalidrawMCPClientConfiguration.configuration(
                kind: credential.kind, endpoint: "http://127.0.0.1:\(port)/mcp", token: credential.token
            )
        } catch { credentialError = error.localizedDescription; return nil }
    }

    private static func authorizedServiceMode(_ mode: ExcalidrawMCPServiceMode) -> ExcalidrawMCPServiceMode {
        guard mode == .optimized,
              !Store.shared.canUseOptimizedMCPServices else {
            return mode
        }
        return .basic
    }
}
