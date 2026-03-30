import Common

struct MonitorAssignmentEntry: ConvenienceMutable, Equatable {
    var matcher: MonitorAssignmentMatcher = MonitorAssignmentMatcher()
    var assignments: [String: [MonitorDescription]] = [:]
}

struct MonitorAssignmentMatcher: ConvenienceMutable, Equatable {
    var numberOfMonitors: Int? = nil
}

private let matcherParsers: [String: any ParserProtocol<MonitorAssignmentMatcher>] = [
    "number-of-monitors": Parser(\.numberOfMonitors, upcast(parseInt)),
]

private func upcast<T>(_ fun: @escaping @Sendable (OrderedJson, ConfigBacktrace) -> ResOrConfigParseDiagnostic<T>) -> @Sendable (OrderedJson, ConfigBacktrace) -> ResOrConfigParseDiagnostic<T?> {
    { fun($0, $1).map { $0 } }
}

func parseWorkspaceToMonitorAssignment(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [MonitorAssignmentEntry] {
    guard let rawArray = raw.asArrayOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .array, actual: raw.tomlType, backtrace)]
        return []
    }
    return rawArray.enumerated().compactMap { (index, element) in
        parseMonitorAssignmentEntry(element, backtrace + .index(index), &c)
    }
}

private func parseMonitorAssignmentEntry(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> MonitorAssignmentEntry? {
    guard let table = raw.asDictOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return nil
    }

    var entry = MonitorAssignmentEntry()

    for (key, value) in table {
        let keyBacktrace = backtrace + .key(key)
        if key == "if" {
            entry.matcher = parseTable(value, MonitorAssignmentMatcher(), matcherParsers, keyBacktrace, &c)
        } else {
            entry.assignments[key] = parseMonitorDescriptions(value, keyBacktrace, &c)
        }
    }

    return entry
}

func parseMonitorDescriptions(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> [MonitorDescription] {
    if let array = raw.asArrayOrNil {
        return array.enumerated()
            .map { (index, rawDesc) in parseMonitorDescription(rawDesc, backtrace + .index(index)).getOrNil(appendErrorTo: &c.errors) }
            .filterNotNil()
    } else {
        return parseMonitorDescription(raw, backtrace).getOrNil(appendErrorTo: &c.errors).asList()
    }
}

func parseMonitorDescription(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<MonitorDescription> {
    let rawString: String
    if let string = raw.asStringOrNil {
        rawString = string
    } else if let int = raw.asIntOrNil {
        rawString = String(int)
    } else {
        return .failure(expectedActualTypeDiagnostic(expected: [.string, .int], actual: raw.tomlType, backtrace))
    }

    return parseMonitorDescription(rawString).toParsedConfig(backtrace)
}
