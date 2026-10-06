// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
import OmniWMIPC

extension IPCApplicationBridge {
    @MainActor
    static func windowGroupResponse(
        for request: IPCWindowGroupRequest,
        id: String,
        controller: WMController,
        sessionToken: String
    ) -> IPCResponse {
        IPCWindowGroupRequestExecutor(controller: controller, sessionToken: sessionToken)
            .response(for: request, id: id)
    }
}
