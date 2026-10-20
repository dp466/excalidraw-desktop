//
//  AdjustElementsTool operation module.
//

import Foundation

extension AdjustElementsMiddleware {
    func applyUpdateOp(
        _ op: UpdateOp,
        elements: inout [ExcalidrawElement],
        updatedElementIds: inout [String]
    ) throws {
        let result = try patchElement(
            elements,
            targetIndex: try indexOfElement(op.id, in: elements),
            patch: op.patch
        )
        elements = result.elements
        updatedElementIds.append(op.id)
        for parentID in result.touchedParentIDs where !updatedElementIds.contains(parentID) {
            updatedElementIds.append(parentID)
        }
    }

    func patchElement(
        _ elements: [ExcalidrawElement],
        targetIndex: Int,
        patch: ElementPatch
    ) throws -> PatchResult {
        let stylePatch = hydratedStylePreset(patch.stylePreset).merged(with: patch.style)
        var newElements = elements
        var touchedParents: [String] = []
        let element = elements[targetIndex]

        switch element {
            case .text(var item):
                if let text = patch.text ?? patch.label {
                    item.text = text
                    item.originalText = text
                    if patch.bounds?.width == nil {
                        item.width = defaultTextWidth(text: text, fontSize: stylePatch.fontSize ?? item.fontSize)
                    }
                    if patch.bounds?.height == nil {
                        item.height = defaultTextHeight(text: text, fontSize: stylePatch.fontSize ?? item.fontSize)
                    }
                }
                applyBoundsPatch(&item.x, &item.y, &item.width, &item.height, patch.bounds)
                applyCommonStylePatch(
                    strokeColor: &item.strokeColor,
                    backgroundColor: &item.backgroundColor,
                    strokeWidth: &item.strokeWidth,
                    roughness: &item.roughness,
                    opacity: &item.opacity,
                    style: stylePatch
                )
                if let fontSize = stylePatch.fontSize {
                    item.fontSize = fontSize
                }
                if let fontFamily = stylePatch.fontFamily {
                    item.fontFamily = .int(AdjustElementsTool.fontFamilyID(fontFamily))
                }
                if let textAlign = parseTextAlign(stylePatch.textAlign) {
                    item.textAlign = textAlign
                }
                if let verticalAlign = parseVerticalAlign(stylePatch.verticalAlign) {
                    item.verticalAlign = verticalAlign
                }
                if let locked = patch.locked {
                    item.locked = locked
                }
                if let link = patch.link {
                    item.link = link
                }

                // containerId mutation: bind / unbind text → container shape.
                if let containerPatch = patch.containerId {
                    let oldContainerID = item.containerId
                    let newContainerID = containerPatch.value
                    if oldContainerID != newContainerID {
                        // Detach from old container.
                        if let oldID = oldContainerID,
                           let oldIdx = newElements.firstIndex(where: { $0.id == oldID }) {
                            newElements[oldIdx] = removeBoundElement(newElements[oldIdx], id: item.id)
                            touchedParents.append(oldID)
                        }
                        // Attach to new container (if any) and recenter inside it.
                        if let newID = newContainerID {
                            guard let newIdx = newElements.firstIndex(where: { $0.id == newID }) else {
                                throw AdjustmentError(message: "Container \(newID) not found.")
                            }
                            guard case .generic = newElements[newIdx] else {
                                throw AdjustmentError(message: "Container \(newID) must be rectangle/ellipse/diamond.")
                            }
                            let container = newElements[newIdx]
                            item.x = container.x + (container.width - item.width) / 2
                            item.y = container.y + (container.height - item.height) / 2
                            newElements[newIdx] = appendBoundElement(
                                newElements[newIdx],
                                entry: ExcalidrawBoundElement(id: item.id, type: .text)
                            )
                            touchedParents.append(newID)
                        }
                        item.containerId = newContainerID
                    }
                }

                bump(&item.version, &item.versionNonce, &item.updated)
                newElements[targetIndex] = .text(item)

            case .generic(var item):
                if patch.text != nil {
                    throw AdjustmentError(message: "Text patch is only supported for text elements. Use `label` to update a shape's bound label.")
                }
                if patch.containerId != nil {
                    throw AdjustmentError(message: "containerId only applies to text elements.")
                }
                let previousX = item.x
                let previousY = item.y
                let previousWidth = item.width
                let previousHeight = item.height
                applyBoundsPatch(&item.x, &item.y, &item.width, &item.height, patch.bounds)
                applyCommonStylePatch(
                    strokeColor: &item.strokeColor,
                    backgroundColor: &item.backgroundColor,
                    strokeWidth: &item.strokeWidth,
                    roughness: &item.roughness,
                    opacity: &item.opacity,
                    style: stylePatch
                )
                if let locked = patch.locked {
                    item.locked = locked
                }
                if let link = patch.link {
                    item.link = link
                }
                bump(&item.version, &item.versionNonce, &item.updated)
                newElements[targetIndex] = .generic(item)
                if let label = patch.label {
                    let labelID = try patchBoundLabel(
                        label,
                        container: item,
                        elements: &newElements
                    )
                    touchedParents.append(labelID)
                } else if patch.bounds != nil {
                    if item.width != previousWidth || item.height != previousHeight {
                        touchedParents.append(
                            contentsOf: recenterBoundLabels(
                                for: item,
                                elements: &newElements
                            )
                        )
                    } else if item.x != previousX || item.y != previousY {
                        touchedParents.append(
                            contentsOf: moveBoundLabels(
                                for: item,
                                dx: item.x - previousX,
                                dy: item.y - previousY,
                                elements: &newElements
                            )
                        )
                    }
                }

            case .linear(var item):
                if patch.text != nil || patch.label != nil || patch.containerId != nil {
                    throw AdjustmentError(message: "Lines accept only bounds/style patches.")
                }
                applyBoundsPatch(&item.x, &item.y, &item.width, &item.height, patch.bounds)
                applyCommonStylePatch(
                    strokeColor: &item.strokeColor,
                    backgroundColor: &item.backgroundColor,
                    strokeWidth: &item.strokeWidth,
                    roughness: &item.roughness,
                    opacity: &item.opacity,
                    style: stylePatch
                )
                if let locked = patch.locked {
                    item.locked = locked
                }
                if let link = patch.link {
                    item.link = link
                }
                bump(&item.version, &item.versionNonce, &item.updated)
                newElements[targetIndex] = .linear(item)

            case .arrow(var item):
                if patch.text != nil || patch.label != nil || patch.containerId != nil {
                    throw AdjustmentError(message: "Arrows accept only bounds/style patches.")
                }
                applyBoundsPatch(&item.x, &item.y, &item.width, &item.height, patch.bounds)
                applyCommonStylePatch(
                    strokeColor: &item.strokeColor,
                    backgroundColor: &item.backgroundColor,
                    strokeWidth: &item.strokeWidth,
                    roughness: &item.roughness,
                    opacity: &item.opacity,
                    style: stylePatch
                )
                if let locked = patch.locked {
                    item.locked = locked
                }
                if let link = patch.link {
                    item.link = link
                }
                bump(&item.version, &item.versionNonce, &item.updated)
                newElements[targetIndex] = .arrow(item)

            case .image(var item):
                if patch.text != nil || patch.label != nil || patch.containerId != nil {
                    throw AdjustmentError(message: "Images accept only bounds/style patches.")
                }
                applyBoundsPatch(&item.x, &item.y, &item.width, &item.height, patch.bounds)
                let imageStylePatch = patch.stylePreset == nil ? patch.style : stylePatch
                applyCommonStylePatch(
                    strokeColor: &item.strokeColor,
                    backgroundColor: &item.backgroundColor,
                    strokeWidth: &item.strokeWidth,
                    roughness: &item.roughness,
                    opacity: &item.opacity,
                    style: imageStylePatch
                )
                if let locked = patch.locked {
                    item.locked = locked
                }
                if let link = patch.link {
                    item.link = link
                }
                bump(&item.version, &item.versionNonce, &item.updated)
                newElements[targetIndex] = .image(item)

            default:
                throw AdjustmentError(message: "Patch only supports text, rectangle, ellipse, diamond, line, arrow, and image elements.")
        }

        return PatchResult(elements: newElements, touchedParentIDs: touchedParents)
    }

    private func patchBoundLabel(
        _ label: String,
        container: ExcalidrawGenericElement,
        elements: inout [ExcalidrawElement]
    ) throws -> String {
        guard let labelIndex = boundLabelTextIndices(
            for: container,
            in: elements
        ).first else {
            throw AdjustmentError(
                message: "Element \(container.id) has no bound text label. Patch the text element directly or create a label first."
            )
        }
        guard case .text(var textElement) = elements[labelIndex] else {
            throw AdjustmentError(message: "Bound label for \(container.id) is not a text element.")
        }

        textElement.text = label
        textElement.originalText = label
        textElement.width = defaultTextWidth(text: label, fontSize: textElement.fontSize)
        textElement.height = defaultTextHeight(text: label, fontSize: textElement.fontSize)
        textElement.x = container.x + (container.width - textElement.width) / 2
        textElement.y = container.y + (container.height - textElement.height) / 2
        textElement.containerId = container.id
        bump(&textElement.version, &textElement.versionNonce, &textElement.updated)
        elements[labelIndex] = .text(textElement)
        return textElement.id
    }

    func boundLabelTextIndices(
        for container: ExcalidrawGenericElement,
        in elements: [ExcalidrawElement]
    ) -> [Int] {
        let boundTextIDs = Set(
            (container.boundElements ?? [])
                .filter { $0.type == .text }
                .map(\.id)
        )
        guard !boundTextIDs.isEmpty || elements.contains(where: {
            guard case .text(let text) = $0, !text.isDeleted else { return false }
            return text.containerId == container.id
        }) else {
            return []
        }

        return elements.indices.filter { index in
            guard case .text(let text) = elements[index], !text.isDeleted else {
                return false
            }
            return boundTextIDs.contains(text.id) || text.containerId == container.id
        }
    }

    func moveBoundLabels(
        for container: ExcalidrawGenericElement,
        dx: Double,
        dy: Double,
        elements: inout [ExcalidrawElement]
    ) -> [String] {
        var updatedIDs: [String] = []
        for index in boundLabelTextIndices(for: container, in: elements) {
            guard case .text(var textElement) = elements[index] else { continue }
            textElement.x += dx
            textElement.y += dy
            textElement.containerId = container.id
            bump(&textElement.version, &textElement.versionNonce, &textElement.updated)
            elements[index] = .text(textElement)
            appendUpdatedElementID(textElement.id, to: &updatedIDs)
        }
        return updatedIDs
    }

    func recenterBoundLabels(
        for container: ExcalidrawGenericElement,
        elements: inout [ExcalidrawElement]
    ) -> [String] {
        var updatedIDs: [String] = []
        for index in boundLabelTextIndices(for: container, in: elements) {
            guard case .text(var textElement) = elements[index] else { continue }
            textElement.x = container.x + (container.width - textElement.width) / 2
            textElement.y = container.y + (container.height - textElement.height) / 2
            textElement.containerId = container.id
            bump(&textElement.version, &textElement.versionNonce, &textElement.updated)
            elements[index] = .text(textElement)
            appendUpdatedElementID(textElement.id, to: &updatedIDs)
        }
        return updatedIDs
    }

    func appendUpdatedElementID(_ id: String, to ids: inout [String]) {
        if !ids.contains(id) {
            ids.append(id)
        }
    }

}
