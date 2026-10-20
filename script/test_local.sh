#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain.sh"
python3 "$ROOT/script/test_diagram_plugin.py"
python3 "$ROOT/script/test_verify_patch.py"
EDITOR_CACHE_ROOT="${EDITOR_CACHE_ROOT:-${TMPDIR:-/private/tmp}/excalidraw-editor-source}"
EDITOR_CACHE_ROOT="$EDITOR_CACHE_ROOT" "$ROOT/script/prepare_editor_cache.sh"
cd "$EDITOR_CACHE_ROOT"
"$NODE" "$YARN_JS" test:typecheck
"$NODE" node_modules/vitest/vitest.mjs run excalidraw-app/excalidrawZ packages/excalidraw/tests/excalidrawZFileLoad.test.tsx --reporter=dot
cd "$ROOT"
DERIVED="${DERIVED:-${TMPDIR:-/private/tmp}/excalidraw-test-derived-data}"
PACKAGES="${PACKAGES:-${TMPDIR:-/private/tmp}/excalidraw-test-source-packages}"
SOURCE_ROOT="$("$ROOT/script/stage_native_snapshot.sh")"
cleanup() { rm -rf "$SOURCE_ROOT"; }
trap cleanup EXIT
NATIVE_SOURCE_ROOT="$SOURCE_ROOT" EDITOR_CACHE_ROOT="$EDITOR_CACHE_ROOT" "$ROOT/script/build_editor.sh"
xcodebuild -resolvePackageDependencies -project "$SOURCE_ROOT/ExcalidrawZ.xcodeproj" -scheme ExcalidrawZ \
  -clonedSourcePackagesDirPath "$PACKAGES" -onlyUsePackageVersionsFromResolvedFile
DEPENDENCY="$PACKAGES/checkouts/ChocofordKit"
[[ "$(git -C "$DEPENDENCY" rev-parse HEAD)" == 239706fbf2b6407ad9d3e755edd9185bcff368e9 ]] || { echo 'Unexpected ChocofordKit revision' >&2; exit 1; }
if git -C "$DEPENDENCY" apply --check "$SOURCE_ROOT/patches/chocofordkit-xcode27.patch" 2>/dev/null; then
  chmod u+w "$DEPENDENCY/Sources/UI/Components/Input/Buttons/FileExporterButton.swift" \
    "$DEPENDENCY/Sources/UI/Components/Input/Buttons/FileImporterButton.swift" \
    "$DEPENDENCY/Sources/UI/Components/Input/Buttons/Styles/OutlinedButtonStyle.swift"
  git -C "$DEPENDENCY" apply "$SOURCE_ROOT/patches/chocofordkit-xcode27.patch"
else
  git -C "$DEPENDENCY" apply --reverse --check "$SOURCE_ROOT/patches/chocofordkit-xcode27.patch"
fi
python3 "$SOURCE_ROOT/script/verify_patch.py" "$DEPENDENCY" "$SOURCE_ROOT/patches/chocofordkit-xcode27.patch"
xcodebuild -project "$SOURCE_ROOT/ExcalidrawZ.xcodeproj" -scheme ExcalidrawZ -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$PACKAGES" \
  -disableAutomaticPackageResolution -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES ENABLE_TESTABILITY=YES \
  -only-testing:ExcalidrawZTests/AppWindowBindingTests \
  -only-testing:ExcalidrawZTests/AutosaveSchedulerTests \
  -only-testing:ExcalidrawZTests/AutosavePersistenceTests \
  -only-testing:ExcalidrawZTests/LocalAutosaveRecoveryStoreTests \
  -only-testing:ExcalidrawZTests/EditorServerContainmentTests \
  -only-testing:ExcalidrawZTests/SaveStreamOrderingTests \
  -only-testing:ExcalidrawZTests/MCPNumberBoundsTests \
  -only-testing:ExcalidrawZTests/ExportToDiskTests \
  -only-testing:ExcalidrawZTests/ImageSceneDecoderTests \
  -only-testing:ExcalidrawZTests/InsertImageTargetTests \
  -only-testing:ExcalidrawZTests/SyncFilesMediaTests \
  -only-testing:ExcalidrawZTests/MediaCleanupTargetedTests \
  -only-testing:ExcalidrawZTests/CollabRoomIDCoderTests \
  -only-testing:ExcalidrawZTests/ArithmeticParserTests \
  -only-testing:ExcalidrawZTests/PublicNetworkHostPolicyTests \
  -only-testing:ExcalidrawZTests/MoveLocalFolderTests \
  -only-testing:ExcalidrawZTests/CloudStorageDateParsingTests \
  -only-testing:ExcalidrawZTests/ExpectedFilesEnumerationTests \
  -only-testing:ExcalidrawZTests/SyncQueueLoadTests \
  -only-testing:ExcalidrawZTests/AIConversationOrderTests \
  -only-testing:ExcalidrawZTests/TransferableFileNameTests \
  -only-testing:ExcalidrawZTests/ImportFilesTests \
  -only-testing:ExcalidrawZTests/AIToolNumberBoundsTests \
  -only-testing:ExcalidrawZTests/CheckpointRowCostTests \
  -only-testing:ExcalidrawZTests/MCPReceiptBoundsTests \
  -only-testing:ExcalidrawZTests/MCPCheckpointStoreBoundsTests \
  -only-testing:ExcalidrawZTests/MCPToolArtifactTests \
  -only-testing:ExcalidrawZTests/TerminationTimeLimitTests \
  -only-testing:ExcalidrawZTests/ScreenAnnotationOpenTargetTests \
  -only-testing:ExcalidrawZTests/FolderMonitorRenameTests \
  -only-testing:ExcalidrawZTests/LocalCheckpointRetentionTests \
  -only-testing:ExcalidrawZTests/ViewportSidecarTests \
  -only-testing:ExcalidrawZTests/TopLevelJSONMemberTests \
  -only-testing:ExcalidrawZTests/CheckpointRetentionTests \
  -only-testing:ExcalidrawZTests/PreviewCachePressureTests \
  -only-testing:ExcalidrawZTests/FileSyncCoordinatorTests \
  -only-testing:ExcalidrawZTests/AppStateSemanticChangeTests \
  -only-testing:ExcalidrawZTests/LocalFileIDMappingTests \
  -only-testing:ExcalidrawZTests/PersistenceEfficiencyTests \
  -only-testing:ExcalidrawZTests/BoundarySaveTests \
  -only-testing:ExcalidrawZTests/LocalFeaturePolicyTests \
  -only-testing:ExcalidrawZTests/LocalFolderContentsLoaderTests \
  -only-testing:ExcalidrawZTests/ActiveFileSnapshotFlushGateTests \
  -only-testing:ExcalidrawZTests/EmbeddedEditorCompatibilityTests \
  -only-testing:ExcalidrawZTests/MCPEmbeddedDiagramTests \
  -only-testing:ExcalidrawZTests/DocumentOpeningTests \
  -only-testing:ExcalidrawZTests/MCPTransportTests \
  -only-testing:ExcalidrawZTests/MCPKeychainCredentialTests \
  -only-testing:ExcalidrawZTests/MCPDocumentCommandTests \
  -only-testing:ExcalidrawZTests/MCPDiagramCommandTests \
  -only-testing:ExcalidrawZTests/MCPRealClientAcceptanceTests/testNativeCommandServiceTransactionAndPersistence \
  -only-testing:ExcalidrawZTests/MCPLibraryAssetStoreTests \
  -only-testing:ExcalidrawZTests/FullDiagramToolTests \
  -only-testing:ExcalidrawZTests/FileCoverPreviewPreparationTests test
