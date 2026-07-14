import AppKit
import Common
import Foundation

struct SaveStateCommand: Command {
    let args: SaveStateCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async -> BinaryExitCode {
        // Get file path from args or config
        guard let filePath = args.filePath ?? config.stateFilePath else {
            return .fail(io.err("No file path provided and 'state-file' not configured in aerospace.toml"))
        }

        let expandedPath = (filePath as NSString).expandingTildeInPath
        let fileUrl = URL(fileURLWithPath: expandedPath)

        // Read existing state file if it exists (for merging)
        var existingWorld: SerializedWorld? = nil
        if let existingData = try? Data(contentsOf: fileUrl),
           let decoded = try? JSONDecoder().decode(SerializedWorld.self, from: existingData) {
            existingWorld = decoded
        }

        // Collect all window data (title and rect) asynchronously
        var windowData: [UInt32: WindowSaveData] = [:]
        for workspace in Workspace.all {
            for window in workspace.allLeafWindowsRecursive {
                let title = (try? await window.getTitle(.nonCancellable)) ?? ""
                let rect = try? await window.getAxRect(.nonCancellable)
                windowData[window.windowId] = WindowSaveData(title: title, rect: rect ?? nil)
            }
        }

        // Create the serialized world, merging with existing state
        let serializedWorld = SerializedWorld(
            workspaces: Workspace.all,
            monitors: monitors,
            windowData: windowData,
            existingWorld: existingWorld
        )

        // Encode to JSON
        guard let jsonData = try? JSONEncoder.aeroSpaceDefault.encode(serializedWorld) else {
            return .fail(io.err("Failed to encode state to JSON"))
        }

        // Write to file
        do {
            try jsonData.write(to: fileUrl)
            io.out("State saved to \(expandedPath)")
            return .succ
        } catch {
            return .fail(io.err("Failed to write state to file: \(error.localizedDescription)"))
        }
    }
}
