// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class SavedWindowGroupMarkCompatibilityTests: XCTestCase {
    private let editor = WindowToken(pid: 97_001, windowId: 97_101)
    private let browser = WindowToken(pid: 97_002, windowId: 97_102)
    private let retired = WindowToken(pid: 97_003, windowId: 97_103)

    func testSameSpellingInBothNamespacesStaysIndependent() throws {
        let controller = try makeController()
        controller.settings.savedWindowGroups = [group("Work", bundleIds: ["com.example.browser"])]
        XCTAssertEqual(controller.windowMarkRegistry.set("Work", for: editor), .inserted)

        let resolution = try resolve("Work", controller)

        XCTAssertEqual(resolution.members.map(\.token), [browser])
        XCTAssertEqual(controller.windowMarkRegistry.lookup("Work"), .found(editor))
        XCTAssertEqual(resolve(failing: "Editor", controller), .unknownGroup)
    }

    func testOneMarkedWindowCanBelongToSeveralGroups() throws {
        let controller = try makeController()
        controller.settings.savedWindowGroups = [
            group("Code", bundleIds: ["com.example.editor"]),
            group("Everything", bundleIds: ["com.example.browser", "com.example.editor"])
        ]
        XCTAssertEqual(controller.windowMarkRegistry.set("primary", for: editor), .inserted)
        XCTAssertEqual(controller.windowMarkRegistry.set("main", for: editor), .inserted)

        XCTAssertEqual(try resolve("Code", controller).members.map(\.token), [editor])
        XCTAssertEqual(try resolve("Everything", controller).members.map(\.token), [browser, editor])
        XCTAssertEqual(controller.windowMarkRegistry.names(for: editor), ["main", "primary"])
    }

    func testGroupQueriesNeverCreateRemoveRekeyOrPruneMarks() throws {
        let controller = try makeController()
        controller.settings.savedWindowGroups = [group("Everything", bundleIds: ["com.example.browser"])]
        XCTAssertEqual(controller.windowMarkRegistry.set("browser", for: browser), .inserted)
        XCTAssertEqual(controller.windowMarkRegistry.set("stale", for: retired), .inserted)
        let marks = controller.windowMarkRegistry.marks
        let executor = IPCWindowGroupRequestExecutor(
            controller: controller,
            sessionToken: "marks",
            reader: reader()
        )

        _ = executor.response(for: .list, id: "1")
        _ = executor.response(for: .inspect(name: "Everything"), id: "2")
        _ = executor.response(for: .resolve(name: "Everything"), id: "3")
        _ = executor.response(for: .resolve(name: "browser"), id: "4")
        let palette = CommandPaletteController(motionPolicy: MotionPolicy(animationsEnabled: false))
        palette.wmController = controller
        palette.selectedMode = .groups
        palette.refreshGroupItems()
        palette.resolveSelectedGroup()

        XCTAssertEqual(controller.windowMarkRegistry.marks, marks)
        XCTAssertEqual(controller.windowMarkRegistry.lookup("stale"), .found(retired))
    }

    func testPersistedGroupsCarryNoMarkNamesOrLiveIdentities() throws {
        let controller = try makeController()
        controller.settings.savedWindowGroups = [group("Everything", bundleIds: ["com.example.browser"])]
        XCTAssertEqual(controller.windowMarkRegistry.set("pinned-browser-mark", for: browser), .inserted)
        _ = try resolve("Everything", controller)

        let text = try String(decoding: SettingsTOMLCodec.encode(controller.settings.toExport()), as: UTF8.self)

        XCTAssertTrue(text.contains("[[savedWindowGroups]]"))
        XCTAssertFalse(text.contains("pinned-browser-mark"))
        for token in [editor, browser, retired] {
            XCTAssertFalse(text.contains(String(token.windowId)))
            XCTAssertFalse(text.contains(String(token.pid)))
        }
        XCTAssertFalse(text.contains(IPCWindowOpaqueID.encode(token: browser, sessionToken: "marks")))
    }

    func testReplacementRekeysTheMarkWhileTheGroupResolvesTheFreshToken() throws {
        let controller = try makeController()
        controller.settings.savedWindowGroups = [group("Code", bundleIds: ["com.example.editor"])]
        XCTAssertEqual(controller.windowMarkRegistry.set("editor", for: editor), .inserted)
        let replacement = WindowToken(pid: editor.pid, windowId: 97_199)
        let workspaceId = try XCTUnwrap(controller.workspaceManager.entry(for: editor)?.workspaceId)

        _ = controller.axEventHandler.commitManagedWindowIdentityRebind(
            from: editor,
            to: replacement,
            axRef: WindowAdmissionTestSupport.axRef(for: replacement),
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: "com.example.editor",
                workspaceId: workspaceId,
                mode: .tiling,
                role: nil,
                subrole: nil,
                title: nil,
                windowLevel: nil,
                parentWindowId: nil,
                frame: nil
            )
        )

        XCTAssertEqual(controller.windowMarkRegistry.lookup("editor"), .found(replacement))
        XCTAssertEqual(try resolve("Code", controller).members.map(\.token), [replacement])
    }

    private func makeController() throws -> WMController {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMSavedGroupMarks")
        let workspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(named: "97", layoutType: .niri, controller: controller)
        )
        _ = WindowAdmissionTestSupport.track(editor, in: workspaceId, controller: controller)
        _ = WindowAdmissionTestSupport.track(browser, in: workspaceId, controller: controller)
        return controller
    }

    private func group(_ name: String, bundleIds: [String]) -> SavedWindowGroup {
        SavedWindowGroup(name: name, scope: .allWorkspaces, include: bundleIds.map { .init(bundleId: $0) })
    }

    private func resolve(_ name: String, _ controller: WMController) throws -> SavedWindowGroupResolution {
        try controller.resolveSavedWindowGroup(named: name, reader: reader()).get()
    }

    private func resolve(failing name: String, _ controller: WMController) -> SavedWindowGroupQueryFailure? {
        guard case let .failure(failure) = controller.resolveSavedWindowGroup(named: name, reader: reader()) else {
            return nil
        }
        return failure
    }

    private func reader() -> SavedWindowGroupSnapshotReader {
        SavedWindowGroupSnapshotReader(
            applicationInfo: { pid in
                let bundleId = switch pid {
                case 97_001: "com.example.editor"
                case 97_002: "com.example.browser"
                default: nil as String?
                }
                return bundleId.map {
                    AppInfoCache.AppInfo(name: $0, bundleId: $0, icon: nil, activationPolicy: .regular)
                }
            },
            windowFacts: { _, _ in
                AXWindowFacts(
                    role: "AXWindow",
                    subrole: "AXStandardWindow",
                    title: "Window",
                    hasCloseButton: true,
                    hasFullscreenButton: true,
                    fullscreenButtonEnabled: true,
                    hasZoomButton: true,
                    hasMinimizeButton: true,
                    appPolicy: .regular,
                    bundleId: nil,
                    attributeFetchSucceeded: true
                )
            }
        )
    }
}
