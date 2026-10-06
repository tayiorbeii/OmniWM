// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension CLIParser {
    static func parseWindowGroupRequest(id: String, arguments: [String]) throws -> IPCRequest {
        guard let actionToken = arguments.first,
              let action = IPCWindowGroupActionName(rawValue: actionToken)
        else {
            throw CLIParseError.usage(usageText)
        }

        switch action {
        case .list:
            guard arguments.count == 1 else {
                throw CLIParseError.usage(usageText)
            }
            return IPCRequest(id: id, windowGroup: .list)
        case .inspect,
             .resolve:
            guard arguments.count == 2 else {
                throw CLIParseError.usage(usageText)
            }
            let name = arguments[1]
            return IPCRequest(id: id, windowGroup: action == .inspect ? .inspect(name: name) : .resolve(name: name))
        }
    }
}
