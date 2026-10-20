//
//  AppDelegate.swift
//  ExcalidrawZ
//
//  Created by Dove Zachary on 2022/12/30.
//

import Foundation
import SwiftUI
import Logging
import CoreSpotlight
import MSAL

extension Notification.Name {
    static let didOpenFromUrls = Notification.Name("DidOpenFromUrls")
}

#if os(macOS)
import AppKit

@MainActor
final class ApplicationTerminationCanvasFlushCoordinator {
    static let shared = ApplicationTerminationCanvasFlushCoordinator()

    private struct WeakFileState { weak var value: FileState? }

    /// One FileState per window. Quitting must save every window's open drawing,
    /// not only the most recently registered one.
    private var fileStates: [WeakFileState] = []

    private init() {}

    private var liveFileStates: [FileState] {
        fileStates.removeAll { $0.value == nil }
        return fileStates.compactMap(\.value)
    }

    func register(fileState: FileState) {
        guard !liveFileStates.contains(where: { $0 === fileState }) else { return }
        fileStates.append(WeakFileState(value: fileState))
    }

    func beginTermination() { liveFileStates.forEach { $0.beginApplicationTermination() } }
    func cancelTermination() { liveFileStates.forEach { $0.cancelApplicationTermination() } }

    func flushPendingCanvasSnapshot() async -> Bool {
        var allSaved = true
        for fileState in liveFileStates {
            let saved = await fileState.flushPendingCanvasSnapshotBeforeTermination()
            allSaved = allSaved && saved
        }
        return allSaved
    }
}

@MainActor
final class ApplicationTerminationPresentationCoordinator: ObservableObject {
    static let shared = ApplicationTerminationPresentationCoordinator()

    @Published private(set) var targetWindowNumber: Int?
    @Published private(set) var stage: ApplicationTerminationStage = .screenAnnotationSaves

    private var cancelAction: (() -> Void)?
    private var forceQuitAction: (() -> Void)?

    private init() {}

    func update(stage: ApplicationTerminationStage) {
        self.stage = stage
    }

    func present(
        on windowNumber: Int,
        cancelAction: @escaping () -> Void,
        forceQuitAction: @escaping () -> Void
    ) {
        self.cancelAction = cancelAction
        self.forceQuitAction = forceQuitAction
        targetWindowNumber = windowNumber
    }

    func dismiss() {
        targetWindowNumber = nil
        cancelAction = nil
        forceQuitAction = nil
    }

    func cancelTermination() {
        let action = cancelAction
        dismiss()
        action?()
    }

    func forceQuit() {
        let action = forceQuitAction
        dismiss()
        action?()
    }
}

enum ApplicationTerminationStage {
    case screenAnnotationSaves
    case backgroundDocumentOperations
    case currentDrawing
    case applicationData
    case backup
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let logger = Logger(label: "AppDelegate")
    private var isHandlingApplicationTermination = false
    private var terminationTask: Task<Void, Never>?
    private var terminationPresentationTask: Task<Void, Never>?

    private static let terminationPresentationDelay: UInt64 = 600_000_000
    
    func applicationWillTerminate(_ notification: Notification) {
        PersistenceController.shared.save()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppRuntime.isRunningTests { return .terminateNow }
        guard !isHandlingApplicationTermination else {
            return .terminateCancel
        }

        isHandlingApplicationTermination = true
        ApplicationTerminationCanvasFlushCoordinator.shared.beginTermination()
        scheduleTerminationSheetIfNeeded(for: sender)
        terminationTask = Task { @MainActor [weak self, weak sender] in
            guard let self, let sender else { return }
            let canTerminate = await prepareForApplicationTermination()
            guard !Task.isCancelled, isHandlingApplicationTermination else {
                return
            }
            finishTerminationRequest(sender, shouldTerminate: canTerminate)
        }
        return .terminateLater
    }

    @MainActor
    private func scheduleTerminationSheetIfNeeded(for application: NSApplication) {
        guard application.isActive,
              let window = application.mainWindow,
              window.isVisible,
              !window.isMiniaturized else {
            return
        }

        let windowNumber = window.windowNumber
        terminationPresentationTask = Task { @MainActor [weak self, weak application] in
            try? await Task.sleep(nanoseconds: Self.terminationPresentationDelay)
            guard let self,
                  let application,
                  !Task.isCancelled,
                  isHandlingApplicationTermination,
                  application.isActive,
                  let targetWindow = application.windows.first(where: {
                      $0.windowNumber == windowNumber
                  }),
                  targetWindow.isVisible,
                  !targetWindow.isMiniaturized else {
                return
            }

            ApplicationTerminationPresentationCoordinator.shared.present(
                on: windowNumber,
                cancelAction: { [weak self, weak application] in
                    guard let self, let application else { return }
                    self.finishTerminationRequest(application, shouldTerminate: false)
                },
                forceQuitAction: { [weak self, weak application] in
                    guard let self, let application else { return }
                    self.finishTerminationRequest(application, shouldTerminate: true)
                }
            )
        }
    }

    @MainActor
    private func finishTerminationRequest(
        _ application: NSApplication,
        shouldTerminate: Bool
    ) {
        guard isHandlingApplicationTermination else { return }
        terminationPresentationTask?.cancel()
        terminationPresentationTask = nil
        terminationTask?.cancel()
        terminationTask = nil
        ApplicationTerminationPresentationCoordinator.shared.dismiss()
        isHandlingApplicationTermination = false
        if !shouldTerminate {
            ApplicationTerminationCanvasFlushCoordinator.shared.cancelTermination()
        }
        application.reply(toApplicationShouldTerminate: shouldTerminate)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    @MainActor
    private func prepareForApplicationTermination() async -> Bool {
        guard !Task.isCancelled else { return false }
        updateTerminationStage(.screenAnnotationSaves)
        await ScreenAnnotationSaveTaskManager.shared.waitUntilIdle()
        guard !Task.isCancelled else { return false }
        updateTerminationStage(.backgroundDocumentOperations)
        await OffscreenExcalidrawEditor.waitForPendingOperations()
        guard !Task.isCancelled else { return false }
        updateTerminationStage(.currentDrawing)
        guard await ApplicationTerminationCanvasFlushCoordinator.shared.flushPendingCanvasSnapshot() else {
            logger.error("Cancelled termination because the current drawing could not be saved")
            return false
        }
        guard !Task.isCancelled else { return false }
        updateTerminationStage(.applicationData)
        PersistenceController.shared.save()
        guard !Task.isCancelled else { return false }
        updateTerminationStage(.backup)
        await backupFilesBeforeTermination()
        return !Task.isCancelled
    }

    @MainActor
    private func updateTerminationStage(_ stage: ApplicationTerminationStage) {
        guard isHandlingApplicationTermination else { return }
        ApplicationTerminationPresentationCoordinator.shared.update(stage: stage)
    }

    @MainActor
    private func backupFilesBeforeTermination() async {
        do {
            try await backupFiles(context: PersistenceController.shared.container.viewContext)
        } catch {
            logger.error("Backup before app termination failed: \(error)")
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // disable auto capitalization
        UserDefaults.standard.set(false, forKey: "NSAutomaticCapitalizationEnabled")
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        logger.info(
            "Remote notification registration succeeded tokenBytes=\(deviceToken.count)"
        )
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        logger.warning("Remote notification registration failed: \(error)")
    }
    
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        logger.info("application did open file")
        return true
    }
    
    func application(_ sender: Any, openFileWithoutUI filename: String) -> Bool {
        return true
    }
    
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        logger.info(#function)
    }
    
    func application(_ application: NSApplication, open urls: [URL]) {
        logger.info("\(#function), urls: \(urls)")
    }
    
    // Continuous Activity
    func application(
        _ application: NSApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
        return handleUserActivity(userActivity)
    }
}

private extension NSApplication {
    @MainActor
    var visibleMainWindows: [NSWindow] {
        windows.filter { window in
            window.isVisible && window.canBecomeMain && !window.isMiniaturized
        }
    }
}


#elseif os(iOS)
import UIKit
class AppDelegate: NSObject, UIApplicationDelegate {
    let logger = Logger(label: "AppDelegate")

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        logger.info(
            "Remote notification registration succeeded tokenBytes=\(deviceToken.count)"
        )
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        logger.warning("Remote notification registration failed: \(error)")
    }

    func application(
        _ application: UIApplication,
        continue userActivity: NSUserActivity,
        restorationHandler: @escaping ([any UIUserActivityRestoring]?) -> Void
    ) -> Bool {
        return handleUserActivity(userActivity)
    }

    func application(
        _ app: UIApplication,
        open url: URL,
        options: [UIApplication.OpenURLOptionsKey: Any] = [:]
    ) -> Bool {
        MSALPublicClientApplication.handleMSALResponse(
            url,
            sourceApplication: options[.sourceApplication] as? String
        )
    }
}
#endif

extension AppDelegate {
//#if canImport(AppKit)
//    typealias PlatformUserActivityRestoring = NSUserActivityRestoring
//#elseif canImport(UIKit)
//    typealias PlatformUserActivityRestoring = UIUserActivityRestoring
//#endif
    func handleUserActivity(
        _ userActivity: NSUserActivity//,
        // restorationHandler: @escaping ([any PlatformUserActivityRestoring]?) -> Void
    ) -> Bool {
        logger.info("[AppDelegate] application received activity: \(userActivity.title ?? "")")
        if userActivity.activityType == CSSearchableItemActionType {
            NotificationCenter.default.post(name: .onContinueUserSearchableItemAction, object: userActivity)
            return true
        }
        if userActivity.activityType == CSQueryContinuationActionType {
            NotificationCenter.default.post(name: .onContinueUserQueryContinuationAction, object: userActivity)
            return true
        }
        
        return false
    }
}
