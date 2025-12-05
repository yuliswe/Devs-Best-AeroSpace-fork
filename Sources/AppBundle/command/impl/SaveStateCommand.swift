import AppKit
import Common
import Foundation

struct SaveStateCommand: Command {
    let args: SaveStateCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        // Get file path from args or config
        guard let filePath = args.filePath ?? config.stateFilePath else {
            return io.err("No file path provided and 'state-file' not configured in aerospace.toml")
        }

        let expandedPath = (filePath as NSString).expandingTildeInPath
        let fileUrl = URL(fileURLWithPath: expandedPath)

        // Collect all window data (title and rect) asynchronously
        var windowData: [UInt32: WindowSaveData] = [:]
        for workspace in Workspace.all {
            for window in workspace.allLeafWindowsRecursive {
                let title = try await window.title
                let rect = try await window.getAxRect()
                windowData[window.windowId] = WindowSaveData(title: title, rect: rect)
            }
        }

        // Create the serialized world
        let serializedWorld = SerializedWorld(
            workspaces: Workspace.all,
            monitors: monitors,
            windowData: windowData
        )

        // Encode to JSON
        guard let jsonData = try? JSONEncoder.aeroSpaceDefault.encode(serializedWorld) else {
            return io.err("Failed to encode state to JSON")
        }

        // Write to file
        do {
            try jsonData.write(to: fileUrl)
            io.out("State saved to \(expandedPath)")
            return true
        } catch {
            return io.err("Failed to write state to file: \(error.localizedDescription)")
        }
    }
}
