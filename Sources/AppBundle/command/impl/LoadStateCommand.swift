import AppKit
import Common
import Foundation

struct LoadStateCommand: Command {
    let args: LoadStateCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        // Get file path from args or config
        guard let filePath = args.filePath ?? config.stateFilePath else {
            return io.err("No file path provided and 'state-file' not configured in aerospace.toml")
        }

        let expandedPath = (filePath as NSString).expandingTildeInPath
        let fileUrl = URL(fileURLWithPath: expandedPath)

        // Read and parse the JSON file
        let jsonData: Data
        do {
            jsonData = try Data(contentsOf: fileUrl)
        } catch {
            return io.err("Failed to read state file: \(error.localizedDescription)")
        }

        let serializedWorld: SerializedWorld
        do {
            serializedWorld = try JSONDecoder().decode(SerializedWorld.self, from: jsonData)
        } catch {
            return io.err("Failed to parse state file: \(error.localizedDescription)")
        }

        // Build a map of current windows with their app bundle ID + title
        var availableWindows: [WindowKey: MacWindow] = [:]
        for window in MacWindow.allWindows {
            let title = try await window.title
            let key = WindowKey(
                appBundleId: window.app.rawAppBundleId ?? "",
                windowTitle: title
            )
            // If there are multiple windows with same key, keep the first one
            if availableWindows[key] == nil {
                availableWindows[key] = window
            }
        }

        var matchedCount = 0
        var unmatchedCount = 0
        
        // Track windows that need position restoration
        var windowsToRestore: [(MacWindow, SerializedWindow)] = []

        // Restore each workspace
        for serializedWorkspace in serializedWorld.workspaces {
            let workspace = Workspace.get(byName: serializedWorkspace.name)

            // Restore floating windows
            for serializedWindow in serializedWorkspace.floatingWindows {
                let key = WindowKey(
                    appBundleId: serializedWindow.appBundleId,
                    windowTitle: serializedWindow.windowTitle
                )
                if let window = availableWindows.removeValue(forKey: key) {
                    window.bindAsFloatingWindow(to: workspace)
                    windowsToRestore.append((window, serializedWindow))
                    matchedCount += 1
                } else {
                    unmatchedCount += 1
                }
            }

            // Restore tiling tree
            // First, unbind the old root container
            let prevRoot = workspace.rootTilingContainer
            let potentialOrphans = prevRoot.allLeafWindowsRecursive
            prevRoot.unbindFromParent()

            // Restore the tree recursively
            restoreSerializedTreeRecursive(
                serializedContainer: serializedWorkspace.rootTilingNode,
                parent: workspace,
                availableWindows: &availableWindows,
                matchedCount: &matchedCount,
                unmatchedCount: &unmatchedCount,
                windowsToRestore: &windowsToRestore
            )

            // Handle orphaned windows (windows that were in the old tree but not in the saved state)
            for window in (potentialOrphans - workspace.rootTilingContainer.allLeafWindowsRecursive) {
                try await window.relayoutWindow(on: workspace, forceTile: true)
            }
        }

        // Set visible workspaces per monitor (safely check bounds)
        let currentMonitors = monitors
        for (index, workspaceName) in serializedWorld.visibleWorkspacePerMonitor.enumerated() {
            if index < currentMonitors.count {
                let workspace = Workspace.get(byName: workspaceName)
                _ = currentMonitors[index].setActiveWorkspace(workspace)
            }
        }

        // Trigger layout refresh before restoring positions
        refreshModel()

        // Restore window positions and sizes
        for (window, serializedWindow) in windowsToRestore {
            if let x = serializedWindow.x, let y = serializedWindow.y {
                let topLeft = CGPoint(x: x, y: y)
                let size: CGSize?
                if let w = serializedWindow.width, let h = serializedWindow.height {
                    size = CGSize(width: w, height: h)
                } else {
                    size = nil
                }
                window.setAxFrame(topLeft, size)
            }
        }

        io.out("State loaded from \(expandedPath)")
        io.out("Matched \(matchedCount) windows, \(unmatchedCount) windows not found")
        return true
    }
}

/// Key for matching windows by app bundle ID and title
private struct WindowKey: Hashable {
    let appBundleId: String
    let windowTitle: String
}

@MainActor
private func restoreSerializedTreeRecursive(
    serializedContainer: SerializedContainer,
    parent: NonLeafTreeNodeObject,
    availableWindows: inout [WindowKey: MacWindow],
    matchedCount: inout Int,
    unmatchedCount: inout Int,
    windowsToRestore: inout [(MacWindow, SerializedWindow)]
) {
    let orientation: Orientation = serializedContainer.orientation == "h" ? .h : .v
    let layout: Layout = serializedContainer.layout == "accordion" ? .accordion : .tiles

    let container = TilingContainer(
        parent: parent,
        adaptiveWeight: serializedContainer.weight,
        orientation,
        layout,
        index: INDEX_BIND_LAST
    )

    // Use INDEX_BIND_LAST for all children to append them in order
    // This avoids index out of bounds when some windows aren't found
    for child in serializedContainer.children {
        switch child {
        case .window(let serializedWindow):
            let key = WindowKey(
                appBundleId: serializedWindow.appBundleId,
                windowTitle: serializedWindow.windowTitle
            )
            if let window = availableWindows.removeValue(forKey: key) {
                window.bind(to: container, adaptiveWeight: serializedWindow.weight, index: INDEX_BIND_LAST)
                windowsToRestore.append((window, serializedWindow))
                matchedCount += 1
            } else {
                // Window not found - skip it gracefully
                unmatchedCount += 1
            }
        case .container(let nestedContainer):
            restoreSerializedTreeRecursive(
                serializedContainer: nestedContainer,
                parent: container,
                availableWindows: &availableWindows,
                matchedCount: &matchedCount,
                unmatchedCount: &unmatchedCount,
                windowsToRestore: &windowsToRestore
            )
        }
    }
}
