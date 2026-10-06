// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Carbon
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class CommandPaletteGroupTests: XCTestCase {
    private let browserOne = WindowToken(pid: 95_001, windowId: 95_101)
    private let browserTwo = WindowToken(pid: 95_001, windowId: 95_102)
    private let editor = WindowToken(pid: 95_002, windowId: 95_103)

    func testGroupsModeKeepsTheCompactSearchFieldWidth() {
        XCTAssertEqual(CommandPaletteMode.allCases.last, .groups)
        XCTAssertEqual(CommandPaletteModePicker.compactWidth, 304)
        XCTAssertEqual(CommandPalettePresentation.searchPlaceholder(for: .groups), "Search saved window groups...")
    }

    func testGroupRowsListEveryConfiguredGroupAndFilterByName() throws {
        let (controller, _) = try makeController()
        controller.settings.savedWindowGroups = [
            browsers(),
            SavedWindowGroup(name: "Notes", scope: .activeWorkspace, include: [.init(bundleId: "com.example.notes")]),
            SavedWindowGroup(name: "Broken", scope: .allWorkspaces, include: [])
        ]
        let palette = CommandPaletteController(motionPolicy: MotionPolicy(animationsEnabled: false))
        palette.wmController = controller
        palette.selectedMode = .groups

        palette.refreshGroupItems()

        XCTAssertEqual(palette.groupBrowser.items.map(\.group.name), ["Browsers", "Notes", "Broken"])
        XCTAssertEqual(palette.groupBrowser.items.map(\.issues), [[], [], [.emptyInclusions]])
        XCTAssertEqual(palette.currentSelectionList(), [.group(0), .group(1), .group(2)])
        XCTAssertEqual(palette.selectedItemID, .group(0))
        palette.searchText = "no"
        XCTAssertEqual(palette.filteredGroupItems.map(\.group.name), ["Notes"])
        XCTAssertEqual(palette.selectedItemID, .group(1))
        XCTAssertNil(palette.resolvedSelectionAction(for: .primary))
        XCTAssertNil(palette.resolvedSelectionAction(for: .alternate))
    }

    func testEnterResolvesInPlaceAgreesWithIPCAndLeavesWindowsAlone() throws {
        let fixture = CommandPaletteFocusFixture(initialMode: .groups) { environment in
            environment.savedWindowGroupReader = { _ in self.reader() }
        }
        defer { fixture.cleanup() }
        let workspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(named: "95", layoutType: .niri, controller: fixture.controller)
        )
        for token in [editor, browserTwo, browserOne] {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: fixture.controller)
        }
        XCTAssertEqual(fixture.controller.windowMarkRegistry.set("Browsers", for: editor), .inserted)
        fixture.controller.settings.savedWindowGroups = [browsers()]
        _ = try fixture.show()
        XCTAssertEqual(fixture.palette.selectedMode, .groups)
        XCTAssertEqual(fixture.palette.selectedItemID, .group(0))
        fixture.palette.selectCurrent()
        XCTAssertTrue(fixture.palette.isExpanded)
        XCTAssertNil(fixture.palette.selectedGroupResolution)
        let worldSeq = fixture.controller.workspaceManager.worldSeq
        let marks = fixture.controller.windowMarkRegistry.marks
        let focus = fixture.controller.workspaceManager.nativeManagedFocusToken

        fixture.palette.selectCurrent()

        XCTAssertTrue(fixture.palette.isVisible)
        let resolution = try XCTUnwrap(fixture.palette.selectedGroupResolution)
        let resolved = try resolution.outcome.get()
        XCTAssertEqual(resolved.status, .resolved)
        XCTAssertEqual(resolution.members.map(\.id), [browserOne, browserTwo])
        XCTAssertEqual(resolution.members.map(\.appName), ["com.example.browser", "com.example.browser"])
        XCTAssertEqual(resolution.members.map(\.workspaceName), ["95", "95"])

        let executor = IPCWindowGroupRequestExecutor(
            controller: fixture.controller,
            sessionToken: "palette-agreement",
            reader: reader()
        )
        guard case let .windowGroupResolution(ipc)? = executor.response(for: .resolve(name: "Browsers"), id: "1")
            .result?.payload
        else {
            return XCTFail("expected IPC resolution")
        }
        XCTAssertEqual(ipc.status, .resolved)
        XCTAssertEqual(
            ipc.members.map(\.id),
            resolution.members.map { IPCWindowOpaqueID.encode(token: $0.id, sessionToken: "palette-agreement") }
        )

        XCTAssertEqual(fixture.controller.workspaceManager.worldSeq, worldSeq)
        XCTAssertEqual(fixture.controller.windowMarkRegistry.marks, marks)
        XCTAssertEqual(fixture.controller.workspaceManager.nativeManagedFocusToken, focus)
    }

    func testIncompleteNoMatchAndFailureDiagnosticsAreShownWithoutGuessing() throws {
        let (controller, _) = try makeController()
        controller.settings.savedWindowGroups = [
            SavedWindowGroup(
                name: "Drafts",
                scope: .allWorkspaces,
                include: [.init(bundleId: "com.example.editor", titleSubstring: "Draft")]
            ),
            SavedWindowGroup(name: "Nothing", scope: .allWorkspaces, include: [.init(bundleId: "com.example.none")]),
            SavedWindowGroup(name: "Broken", scope: .allWorkspaces, include: [.init(bundleId: "")]),
            SavedWindowGroup(name: "Here", scope: .activeWorkspace, include: [.init(bundleId: "com.example.editor")])
        ]
        controller.workspaceManager.setInteractionMonitor(nil, preservePrevious: false)
        var environment = CommandPaletteEnvironment()
        environment.savedWindowGroupReader = { _ in self.reader(title: nil) }
        let palette = CommandPaletteController(
            motionPolicy: MotionPolicy(animationsEnabled: false),
            environment: environment
        )
        palette.wmController = controller
        palette.selectedMode = .groups
        palette.refreshGroupItems()

        let drafts = try resolve(palette, 0)
        let draftsResolution = try drafts.outcome.get()
        XCTAssertEqual(draftsResolution.status, .incomplete)
        XCTAssertTrue(drafts.members.isEmpty)
        XCTAssertEqual(drafts.unresolved.map(\.id), [editor])
        XCTAssertEqual(drafts.unresolved.first?.unresolvedClauses.first?.facts, [.title])
        XCTAssertEqual(
            CommandPalettePresentation.groupResolutionSummary(drafts.outcome),
            "Incomplete: 0 matched, 1 unresolved, 0 stale"
        )

        let nothing = try resolve(palette, 1)
        XCTAssertEqual(try nothing.outcome.get().status, .noMatch)
        XCTAssertEqual(CommandPalettePresentation.groupResolutionSummary(nothing.outcome), "No matching windows")

        let broken = try resolve(palette, 2)
        XCTAssertEqual(broken.outcome.failure, .invalidDefinition([.missingBundleId(.init(kind: .include, index: 0))]))
        XCTAssertEqual(
            CommandPalettePresentation.groupResolutionSummary(broken.outcome),
            "Invalid definition: fix it in settings.toml"
        )

        let here = try resolve(palette, 3)
        XCTAssertEqual(here.outcome.failure, .scopeUnavailable(.noFocusedMonitor))
        XCTAssertEqual(
            CommandPalettePresentation.groupResolutionSummary(here.outcome),
            "No focused monitor: the active workspace is unavailable"
        )

        controller.settings.savedWindowGroups.removeLast()
        let removed = try resolve(palette, 3)
        XCTAssertEqual(removed.outcome.failure, .unknownGroup)
    }

    func testResolvedSummaryCountsMembers() {
        let group = browsers()
        let resolution = SavedWindowGroupResolution(
            group: group,
            scope: .allWorkspaces,
            members: [
                .init(
                    token: browserOne,
                    workspaceId: UUID(),
                    isAppHidden: false,
                    clauseIndex: 0,
                    unresolvedClauses: []
                ),
                .init(token: browserTwo, workspaceId: UUID(), isAppHidden: true, clauseIndex: 0, unresolvedClauses: [])
            ],
            unresolved: [],
            stale: []
        )
        XCTAssertEqual(CommandPalettePresentation.groupResolutionSummary(.success(resolution)), "Resolved: 2 matched")
    }

    private func resolve(_ palette: CommandPaletteController, _ index: Int) throws -> CommandPaletteGroupResolution {
        palette.selectedItemID = .group(index)
        palette.resolveSelectedGroup()
        return try XCTUnwrap(palette.selectedGroupResolution)
    }

    private func makeController() throws -> (WMController, WorkspaceDescriptor.ID) {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMPaletteGroups")
        let workspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(named: "96", layoutType: .niri, controller: controller)
        )
        for token in [editor, browserTwo, browserOne] {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        return (controller, workspaceId)
    }

    private func browsers() -> SavedWindowGroup {
        SavedWindowGroup(name: "Browsers", scope: .allWorkspaces, include: [.init(bundleId: "com.example.browser")])
    }

    private func reader(title: String? = "Window") -> SavedWindowGroupSnapshotReader {
        SavedWindowGroupSnapshotReader(
            applicationInfo: { pid in
                let bundleId = switch pid {
                case 95_001: "com.example.browser"
                case 95_002: "com.example.editor"
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
                    title: title,
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

private extension Result {
    var failure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
