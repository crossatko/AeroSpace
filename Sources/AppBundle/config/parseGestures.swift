private let gesturesParserTable: [String: any ParserProtocol<Gestures>] = [
    "workspace-swipe": Parser(\.workspaceSwipe, parseBool),
    "workspace-swipe-fingers": Parser(\.workspaceSwipeFingers) { raw, backtrace in
        parseInt(raw, backtrace).flatMap { n in
            (3...4).contains(n) ? .success(n) : .failure(.init(backtrace, "Expected 3 or 4, got \(n)"))
        }
    },
    "workspace-swipe-threshold": Parser(\.workspaceSwipeThreshold) { raw, backtrace in
        parseInt(raw, backtrace).flatMap { n in
            (1...100).contains(n) ? .success(n) : .failure(.init(backtrace, "Expected a percentage in 1...100, got \(n)"))
        }
    },
    "workspace-swipe-natural": Parser(\.workspaceSwipeNatural, parseBool),
    "workspace-swipe-skip-empty": Parser(\.workspaceSwipeSkipEmpty, parseBool),
    "workspace-swipe-wrap": Parser(\.workspaceSwipeWrap, parseBool),
]

func parseGestures(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> Gestures {
    parseTable(raw, Gestures(), gesturesParserTable, backtrace, &c)
}
