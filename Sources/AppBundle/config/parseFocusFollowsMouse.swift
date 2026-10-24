private let focusFollowsMouseParserTable: [String: any ParserProtocol<FocusFollowsMouse>] = [
    "enabled": Parser(\.enabled, parseBool),
    "mode": Parser(\.mode, parseFocusFollowsMouseMode),
    "delay-ms": Parser(\.delayMs, parseFocusFollowsMouseDelay),
    "raise-apps": Parser(\.raiseApps, parseRaiseApps),
    "debug-log": Parser(\.debugLog, parseBool),
]

func parseFocusFollowsMouse(_ rawConfig: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> FocusFollowsMouse {
    // Shorthand: focus-follows-mouse = 'no-raise'
    if case .string = rawConfig {
        var result = FocusFollowsMouse()
        switch parseFocusFollowsMouseMode(rawConfig, backtrace) {
            case .success(let mode): result.mode = mode
            case .failure(let error): c.errors.append(error)
        }
        return result
    }
    return parseTable(rawConfig, FocusFollowsMouse(), focusFollowsMouseParserTable, backtrace, &c)
}

private func parseFocusFollowsMouseMode(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<FocusFollowsMouseMode?> {
    parseString(raw, backtrace).flatMap {
        FocusFollowsMouseMode(rawValue: $0).map { Optional($0) }
            .toResult(.init(backtrace, "Can't parse focus-follows-mouse mode '\($0)'. Possible values: off, no-raise, raise"))
    }
}

private func parseFocusFollowsMouseDelay(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<Int> {
    parseInt(raw, backtrace).flatMap {
        (0 ... 2000).contains($0) ? .success($0) : .failure(.init(backtrace, "delay-ms must be in 0...2000 range"))
    }
}

private func parseRaiseApps(_ raw: OrderedJson, _ backtrace: ConfigBacktrace) -> ResOrConfigParseDiagnostic<[String]> {
    parseTomlArray(raw, backtrace).flatMap { arr in
        arr.enumerated().mapAllOrFailure { (index, elem) in parseString(elem, backtrace + .index(index)) }
    }
}
