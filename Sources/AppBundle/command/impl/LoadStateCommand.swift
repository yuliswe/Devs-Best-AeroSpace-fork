import AppKit
import Common
import Foundation

struct LoadStateCommand: Command {
    let args: LoadStateCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        let verbose = args.verbose
        // Get file path from args or config
        guard let filePath = args.filePath ?? config.stateFilePath else {
            return .fail(io.err("No file path provided and 'state-file' not configured in aerospace.toml"))
        }

        let expandedPath = (filePath as NSString).expandingTildeInPath
        let fileUrl = URL(fileURLWithPath: expandedPath)

        // Read and parse the JSON file
        let jsonData: Data
        do {
            jsonData = try Data(contentsOf: fileUrl)
        } catch {
            return .fail(io.err("Failed to read state file: \(error.localizedDescription)"))
        }

        let serializedWorld: SerializedWorld
        do {
            serializedWorld = try JSONDecoder().decode(SerializedWorld.self, from: jsonData)
        } catch {
            return .fail(io.err("Failed to parse state file: \(error.localizedDescription)"))
        }

        // Collect all current windows
        var allCurrentWindows: [(MacWindow, String, String)] = [] // (window, appBundleId, title)
        for window in MacWindow.allWindows {
            let title = (try? await window.getTitle(.nonCancellable)) ?? ""
            let appBundleId = window.app.rawAppBundleId ?? ""
            allCurrentWindows.append((window, appBundleId, title))
        }

        // Build app name cache for efficient lookup
        var appNameCache: [String: String] = [:]
        for (_, macApp) in MacApp.allAppsMap {
            if let bundleId = macApp.rawAppBundleId, let name = macApp.name {
                appNameCache[bundleId] = name
            }
        }
        // Also cache from running applications (for apps not in MacApp.allAppsMap)
        for app in NSWorkspace.shared.runningApplications {
            if let bundleId = app.bundleIdentifier, let name = app.localizedName, appNameCache[bundleId] == nil {
                appNameCache[bundleId] = name
            }
        }

        // Phase 1: index serialized windows without touching the tree.
        // Every serialized window gets an ordinal assigned in DFS order (tiling tree
        // first, then floating windows, per workspace). Phase 2 repeats the exact
        // same walk, so ordinals line up between the two phases.
        var stateFileWindows: [WindowKey: [Int]] = [:]
        var ordinal = 0
        for serializedWorkspace in serializedWorld.workspaces {
            indexSerializedWindows(
                serializedContainer: serializedWorkspace.rootTilingNode,
                ordinal: &ordinal,
                stateFileWindows: &stateFileWindows
            )
            for serializedWindow in serializedWorkspace.floatingWindows {
                let key = WindowKey(appBundleId: serializedWindow.appBundleId, title: serializedWindow.windowTitle)
                stateFileWindows[key, default: []].append(ordinal)
                ordinal += 1
            }
        }

        var matchedCount = 0
        var unmatchedCount = 0

        // Which live window (if any) matched each serialized window's ordinal
        var matchedWindowsById: [Int: MacWindow] = [:]

        // Track which windows were matched (for verbose logging)
        var matchedWindows: Set<UInt32> = []

        // Match current windows to serialized windows
        for (window, appBundleId, title) in allCurrentWindows {
            let key = WindowKey(appBundleId: appBundleId, title: title)
            var matchedId: Int? = nil

            if var ids = stateFileWindows[key] {
                // Exact match. Consume one ordinal so it's not matched twice
                matchedId = ids.removeFirst()
                stateFileWindows[key] = ids.isEmpty ? nil : ids
            } else {
                // Fuzzy match: same app, one title contains the other.
                // Candidates are sorted so the pick is deterministic across runs
                let candidates = stateFileWindows.keys
                    .filter { $0.appBundleId == appBundleId }
                    .filter { title == $0.title || title.contains($0.title) || $0.title.contains(title) }
                    .sorted { $0.title < $1.title }
                if let stateKey = candidates.first, var ids = stateFileWindows[stateKey] {
                    matchedId = ids.removeFirst()
                    stateFileWindows[stateKey] = ids.isEmpty ? nil : ids
                }
            }

            if let matchedId = matchedId {
                matchedWindowsById[matchedId] = window
                matchedCount += 1
                matchedWindows.insert(window.windowId)
            } else {
                unmatchedCount += 1
            }
        }

        // Track windows that need position restoration
        var windowsToRestore: [(MacWindow, SerializedWindow)] = []

        // Phase 2: rebuild each workspace tree, binding containers and matched
        // windows in serialized child order so the visual order (left-to-right,
        // top-to-bottom) survives the round-trip, including windows interleaved
        // with sibling containers.
        ordinal = 0
        for serializedWorkspace in serializedWorld.workspaces {
            let workspace = Workspace.get(byName: serializedWorkspace.name)

            // Unbind old root container
            let prevRoot = workspace.rootTilingContainer
            let potentialOrphans = prevRoot.allLeafWindowsRecursive
            prevRoot.unbindFromParent()

            buildTreeAndBindWindows(
                serializedContainer: serializedWorkspace.rootTilingNode,
                parent: workspace,
                ordinal: &ordinal,
                matchedWindowsById: matchedWindowsById,
                windowsToRestore: &windowsToRestore
            )

            for serializedWindow in serializedWorkspace.floatingWindows {
                if let window = matchedWindowsById[ordinal] {
                    window.bindAsFloatingWindow(to: workspace)
                    windowsToRestore.append((window, serializedWindow))
                }
                ordinal += 1
            }

            // Handle orphaned windows
            for window in (potentialOrphans - workspace.rootTilingContainer.allLeafWindowsRecursive) {
                try? await window.relayoutWindow(on: workspace, .nonCancellable, forceTile: true)
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
        await refreshModel_nonCancellable()

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

        // Output verbose logs if requested - loop through current windows
        if verbose {
            for (window, appBundleId, title) in allCurrentWindows {
                let appName = window.app.name ?? appNameCache[appBundleId] ?? appBundleId
                if matchedWindows.contains(window.windowId) {
                    io.out("\(appName) | \(title) (matched by app/window name)")
                } else {
                    io.out("\(appName) | \(title) (unmatched)")
                }
            }
        }

        return .succ
    }
}

private struct WindowKey: Hashable {
    let appBundleId: String
    let title: String
}

/// Phase 1 walk: index every serialized window in the tiling tree by
/// (appBundleId, title), assigning ordinals in DFS order. Duplicate keys keep
/// all their ordinals so several same-titled windows can each claim a slot.
private func indexSerializedWindows(
    serializedContainer: SerializedContainer,
    ordinal: inout Int,
    stateFileWindows: inout [WindowKey: [Int]]
) {
    for child in serializedContainer.children {
        switch child {
        case .window(let serializedWindow):
            let key = WindowKey(appBundleId: serializedWindow.appBundleId, title: serializedWindow.windowTitle)
            stateFileWindows[key, default: []].append(ordinal)
            ordinal += 1
        case .container(let nestedContainer):
            indexSerializedWindows(
                serializedContainer: nestedContainer,
                ordinal: &ordinal,
                stateFileWindows: &stateFileWindows
            )
        }
    }
}

/// Phase 2 walk: build the tree structure and bind matched windows, visiting
/// children in serialized order so both containers and windows end up at the
/// positions they were saved in. Must visit windows in the same DFS order as
/// `indexSerializedWindows` for the ordinals to line up.
@MainActor
private func buildTreeAndBindWindows(
    serializedContainer: SerializedContainer,
    parent: NonLeafTreeNodeObject,
    ordinal: inout Int,
    matchedWindowsById: [Int: MacWindow],
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

    for child in serializedContainer.children {
        switch child {
        case .window(let serializedWindow):
            if let window = matchedWindowsById[ordinal] {
                window.bind(to: container, adaptiveWeight: serializedWindow.weight, index: INDEX_BIND_LAST)
                windowsToRestore.append((window, serializedWindow))
            }
            ordinal += 1
        case .container(let nestedContainer):
            buildTreeAndBindWindows(
                serializedContainer: nestedContainer,
                parent: container,
                ordinal: &ordinal,
                matchedWindowsById: matchedWindowsById,
                windowsToRestore: &windowsToRestore
            )
        }
    }
}
