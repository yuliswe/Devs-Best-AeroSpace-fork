public struct LoadStateCmdArgs: CmdArgs {
    public let rawArgsForStrRepr: EquatableNoop<StrArrSlice>
    public init(rawArgs: StrArrSlice) { self.rawArgsForStrRepr = .init(rawArgs) }
    public static let parser: CmdParser<Self> = cmdParser(
        kind: .loadState,
        allowInConfig: true,
        help: load_state_help_generated,
        flags: [:],
        posArgs: [ArgParser(\.filePath, parseOptionalLoadFilePath)],
    )

    public var filePath: String? = nil
    /*conforms*/ public var windowId: UInt32?
    /*conforms*/ public var workspaceName: WorkspaceName?
}

private func parseOptionalLoadFilePath(i: ArgParserInput) -> ParsedCliArgs<String?> {
    .succ(i.arg, advanceBy: 1)
}

public let load_state_help_generated: String = """
    USAGE: load-state [<file-path>]

    OPTIONS:
      -h, --help   Print help

    ARGUMENTS:
      <file-path>  Path to the file from which state will be loaded (JSON format).
                   If not provided, uses 'state-file' from config.
    """
