//
//  ExcalidrawDocumentAppStatePersistence.swift
//  ExcalidrawZ
//
//  Created by Codex on 2026/6/30.
//

import Foundation

enum ExcalidrawDocumentAppStatePersistence {
    private static let appStateOnlyPersistentKeys: Set<String> = [
        // Canvas preferences
        // `theme` is intentionally excluded: native appearance settings apply it at runtime.
        "viewBackgroundColor",
        "gridSize",
        "gridStep",
        "gridModeEnabled",
        "zenModeEnabled",
        "viewModeEnabled",
        "objectsSnapModeEnabled",
        "isMidpointSnappingEnabled",
        "bindingPreference",
        "preferredSelectionTool",
        "boxSelectionMode",
        "stats",

        // Drawing defaults
        "currentItemStrokeWidthKey",
        "currentItemStrokeColor",
        "currentItemBackgroundColor",
        "currentItemStrokeStyle",
        "currentItemFillStyle",
        "currentItemRoughness",
        "currentItemOpacity",
        "currentItemFontFamily",
        "currentItemFontSize",
        "currentItemTextAlign",
        "currentItemRoundness",
        "currentItemArrowType",
        "currentItemStartArrowhead",
        "currentItemEndArrowhead",
        "currentItemStrokeVariability"
    ]

    static func documentData(
        _ documentData: Data,
        settingNativeFileName nativeFileName: String?
    ) throws -> Data {
        guard let nativeFileName, !nativeFileName.isEmpty else {
            return documentData
        }

        // Runs on every autosave: rewrite only appState, not every element.
        if let member = TopLevelJSONMember.locate("appState", in: documentData) {
            var appState: [String: Any] = [:]
            if let valueData = member.value(in: documentData) {
                guard let object = try JSONSerialization.jsonObject(
                    with: valueData,
                    options: .fragmentsAllowed
                ) as? [String: Any] else {
                    return try documentDataByParsingDocument(documentData, settingNativeFileName: nativeFileName)
                }
                appState = object
            }
            if appState["name"] as? String == nativeFileName {
                return documentData
            }
            appState["name"] = nativeFileName
            return try member.replacingValue(
                in: documentData,
                with: JSONSerialization.data(withJSONObject: appState),
                key: "appState"
            )
        }
        return try documentDataByParsingDocument(documentData, settingNativeFileName: nativeFileName)
    }

    private static func documentDataByParsingDocument(
        _ documentData: Data,
        settingNativeFileName nativeFileName: String
    ) throws -> Data {
        guard var documentObject = try JSONSerialization.jsonObject(with: documentData) as? [String: Any] else {
            return documentData
        }

        var appState = documentObject["appState"] as? [String: Any] ?? [:]
        appState["name"] = nativeFileName
        documentObject["appState"] = appState

        return try JSONSerialization.data(withJSONObject: documentObject)
    }

    static func appStateObjectByKeepingAppStateOnlyPersistentFields(from appStateObject: Any) -> [String: Any] {
        guard let appState = appStateObject as? [String: Any] else {
            return [String: Any]()
        }

        return appState.filter { appStateOnlyPersistentKeys.contains($0.key) }
    }

    static func appStateObjectByMergingAppStateOnlyPersistentFields(
        from appStateObject: Any,
        into existingAppStateObject: Any,
        nativeFileName: String?
    ) -> Any {
        var mergedAppState = existingAppStateObject as? [String: Any] ?? [:]
        let appState = appStateObject as? [String: Any] ?? [:]

        for key in appStateOnlyPersistentKeys {
            if let value = appState[key] {
                mergedAppState[key] = value
            } else {
                mergedAppState.removeValue(forKey: key)
            }
        }

        if let nativeFileName, !nativeFileName.isEmpty {
            mergedAppState["name"] = nativeFileName
        }

        return mergedAppState
    }

}
