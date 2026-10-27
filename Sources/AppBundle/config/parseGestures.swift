private let gesturesParserTable: [String: any ParserProtocol<Gestures>] = [
    "workspace-swipe": Parser(\.workspaceSwipe, parseBool),
    "workspace-swipe-fingers": Parser(\.workspaceSwipeFingers) { raw, backtrace in
        parseInt(raw, backtrace).flatMap { n in
            (3 ... 4).contains(n) ? .success(n) : .failure(.init(backtrace, "Expected 3 or 4, got \(n)"))
        }
    },
    "workspace-swipe-threshold": Parser(\.workspaceSwipeThreshold) { raw, backtrace in
        parseInt(raw, backtrace).flatMap { n in
            (1 ... 100).contains(n) ? .success(n) : .failure(.init(backtrace, "Expected a percentage in 1...100, got \(n)"))
        }
    },
    "workspace-swipe-natural": Parser(\.workspaceSwipeNatural, parseBool),
    "workspace-swipe-skip-empty": Parser(\.workspaceSwipeSkipEmpty, parseBool),
    "workspace-swipe-wrap": Parser(\.workspaceSwipeWrap, parseBool),
    "magic-mouse-swipe": Parser(\.magicMouseSwipe, parseBool),
    "magic-mouse-swipe-fingers": Parser(\.magicMouseSwipeFingers) { raw, backtrace in
        parseInt(raw, backtrace).flatMap { n in
            (1 ... 3).contains(n) ? .success(n) : .failure(.init(backtrace, "Expected 1, 2 or 3, got \(n)"))
        }
    },
    "magic-mouse-swipe-threshold": Parser(\.magicMouseSwipeThreshold) { raw, backtrace in
        parseInt(raw, backtrace).flatMap { n in
            (1 ... 100).contains(n) ? .success(n) : .failure(.init(backtrace, "Expected a percentage in 1...100, got \(n)"))
        }
    },
]

func parseGestures(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext) -> Gestures {
    parseTable(raw, Gestures(), gesturesParserTable, backtrace, &c)
}
