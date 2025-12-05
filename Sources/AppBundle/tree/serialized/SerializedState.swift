import AppKit
import Common

/// Serializable tree node that can be either a container or a window
enum SerializedTreeNode: Codable, Sendable {
    case container(SerializedContainer)
    case window(SerializedWindow)

    enum CodingKeys: String, CodingKey {
        case type
        case layout
        case orientation
        case weight
        case children
        case appBundleId
        case windowTitle
        case x, y, width, height
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "container":
            let layout = try container.decode(String.self, forKey: .layout)
            let orientation = try container.decode(String.self, forKey: .orientation)
            let weight = try container.decode(CGFloat.self, forKey: .weight)
            let children = try container.decode([SerializedTreeNode].self, forKey: .children)
            self = .container(SerializedContainer(children: children, layout: layout, orientation: orientation, weight: weight))
        case "window":
            let appBundleId = try container.decode(String.self, forKey: .appBundleId)
            let windowTitle = try container.decode(String.self, forKey: .windowTitle)
            let weight = try container.decode(CGFloat.self, forKey: .weight)
            let x = try container.decodeIfPresent(CGFloat.self, forKey: .x)
            let y = try container.decodeIfPresent(CGFloat.self, forKey: .y)
            let width = try container.decodeIfPresent(CGFloat.self, forKey: .width)
            let height = try container.decodeIfPresent(CGFloat.self, forKey: .height)
            self = .window(SerializedWindow(appBundleId: appBundleId, windowTitle: windowTitle, weight: weight, x: x, y: y, width: width, height: height))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown type: \(type)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .container(let c):
            try container.encode("container", forKey: .type)
            try container.encode(c.layout, forKey: .layout)
            try container.encode(c.orientation, forKey: .orientation)
            try container.encode(c.weight, forKey: .weight)
            try container.encode(c.children, forKey: .children)
        case .window(let w):
            try container.encode("window", forKey: .type)
            try container.encode(w.appBundleId, forKey: .appBundleId)
            try container.encode(w.windowTitle, forKey: .windowTitle)
            try container.encode(w.weight, forKey: .weight)
            try container.encodeIfPresent(w.x, forKey: .x)
            try container.encodeIfPresent(w.y, forKey: .y)
            try container.encodeIfPresent(w.width, forKey: .width)
            try container.encodeIfPresent(w.height, forKey: .height)
        }
    }
}

/// Serializable container node
struct SerializedContainer: Codable, Sendable {
    let children: [SerializedTreeNode]
    let layout: String  // "tiles" | "accordion"
    let orientation: String // "h" | "v"
    let weight: CGFloat

    init(children: [SerializedTreeNode], layout: String, orientation: String, weight: CGFloat) {
        self.children = children
        self.layout = layout
        self.orientation = orientation
        self.weight = weight
    }

    @MainActor
    init(_ container: TilingContainer) {
        children = container.children.compactMap { child -> SerializedTreeNode? in
            switch child.nodeCases {
            case .window(let w):
                return .window(SerializedWindow(w))
            case .tilingContainer(let c):
                return .container(SerializedContainer(c))
            case .workspace,
                 .macosMinimizedWindowsContainer,
                 .macosHiddenAppsWindowsContainer,
                 .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer:
                return nil
            }
        }
        layout = container.layout.rawValue
        orientation = container.orientation == .h ? "h" : "v"
        weight = getWeightOrNil(container) ?? 1
    }
}

/// Serializable window identified by app bundle ID and window title
struct SerializedWindow: Codable, Sendable {
    let appBundleId: String
    let windowTitle: String
    let weight: CGFloat
    // Window position and size (optional for backwards compatibility)
    let x: CGFloat?
    let y: CGFloat?
    let width: CGFloat?
    let height: CGFloat?

    init(appBundleId: String, windowTitle: String, weight: CGFloat, x: CGFloat? = nil, y: CGFloat? = nil, width: CGFloat? = nil, height: CGFloat? = nil) {
        self.appBundleId = appBundleId
        self.windowTitle = windowTitle
        self.weight = weight
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    @MainActor
    init(_ window: Window) {
        appBundleId = window.app.rawAppBundleId ?? ""
        windowTitle = ""
        weight = getWeightOrNil(window) ?? 1
        x = nil
        y = nil
        width = nil
        height = nil
    }
}

/// Data collected for each window during save
struct WindowSaveData: Sendable {
    let title: String
    let rect: Rect?
}

/// Serializable workspace
struct SerializedWorkspace: Codable, Sendable {
    let name: String
    let rootTilingNode: SerializedContainer
    let floatingWindows: [SerializedWindow]

    @MainActor
    init(_ workspace: Workspace, windowData: [UInt32: WindowSaveData]) {
        name = workspace.name
        rootTilingNode = SerializedContainer.createWithData(workspace.rootTilingContainer, windowData: windowData)
        floatingWindows = workspace.floatingWindows.map { window in
            let data = windowData[window.windowId]
            return SerializedWindow(
                appBundleId: window.app.rawAppBundleId ?? "",
                windowTitle: data?.title ?? "",
                weight: getWeightOrNil(window) ?? 1,
                x: data?.rect?.topLeftX,
                y: data?.rect?.topLeftY,
                width: data?.rect?.width,
                height: data?.rect?.height
            )
        }
    }
}

/// The complete serialized world state
struct SerializedWorld: Codable, Sendable {
    let workspaces: [SerializedWorkspace]
    let visibleWorkspacePerMonitor: [String]

    @MainActor
    init(workspaces: [Workspace], monitors: [Monitor], windowData: [UInt32: WindowSaveData]) {
        self.workspaces = workspaces
            .filter { !$0.isEffectivelyEmpty }
            .map { SerializedWorkspace($0, windowData: windowData) }
        self.visibleWorkspacePerMonitor = monitors.map { $0.activeWorkspace.name }
    }
}

// MARK: - Helper Extensions

extension SerializedContainer {
    @MainActor
    static func createWithData(_ container: TilingContainer, windowData: [UInt32: WindowSaveData]) -> SerializedContainer {
        let children = container.children.compactMap { child -> SerializedTreeNode? in
            switch child.nodeCases {
            case .window(let w):
                let data = windowData[w.windowId]
                return .window(SerializedWindow(
                    appBundleId: w.app.rawAppBundleId ?? "",
                    windowTitle: data?.title ?? "",
                    weight: getWeightOrNil(w) ?? 1,
                    x: data?.rect?.topLeftX,
                    y: data?.rect?.topLeftY,
                    width: data?.rect?.width,
                    height: data?.rect?.height
                ))
            case .tilingContainer(let c):
                return .container(createWithData(c, windowData: windowData))
            case .workspace,
                 .macosMinimizedWindowsContainer,
                 .macosHiddenAppsWindowsContainer,
                 .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer:
                return nil
            }
        }
        return SerializedContainer(
            children: children,
            layout: container.layout.rawValue,
            orientation: container.orientation == .h ? "h" : "v",
            weight: getWeightOrNil(container) ?? 1
        )
    }
}

@MainActor
private func getWeightOrNil(_ node: TreeNode) -> CGFloat? {
    ((node.parent as? TilingContainer)?.orientation).map { node.getWeight($0) }
}
