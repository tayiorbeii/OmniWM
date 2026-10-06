// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

extension IPCAutomationManifest {
    public static let windowGroupActionDescriptors: [IPCWindowGroupActionDescriptor] = [
        .init(
            path: "window group list [--json]",
            name: .list,
            summary: "List saved window groups from settings and whether each definition is valid."
        ),
        .init(
            path: "window group inspect <name>",
            name: .inspect,
            summary: "Show a saved window group's matchers, scope, and definition issues without reading windows.",
            arguments: ["name"]
        ),
        .init(
            path: "window group resolve <name>",
            name: .resolve,
            summary: "List the managed windows a saved window group matches now, without changing any window.",
            arguments: ["name"]
        )
    ]
}
