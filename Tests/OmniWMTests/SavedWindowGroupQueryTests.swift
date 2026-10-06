// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class SavedWindowGroupQueryTests: XCTestCase {
    private struct Fixture {
        let controller: WMController
        let leftMonitor: Monitor
        let rightMonitor: Monitor
        let leftWorkspace: WorkspaceDescriptor.ID
        let rightWorkspace: WorkspaceDescriptor.ID
        let inactiveRightWorkspace: WorkspaceDescriptor.ID
    }

    private let leftBrowser = WindowToken(pid: 91_001, windowId: 91_101)
    private let rightBrowser = WindowToken(pid: 91_001, windowId: 91_102)
    private let inactiveBrowser = WindowToken(pid: 91_002, windowId: 91_103)
    private let rightEditor = WindowToken(pid: 91_003, windowId: 91_104)

    func testActiveWorkspaceScopeUsesTheFocusedMonitorsActiveWorkspace() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.savedWindowGroups = [browsers(scope: .activeWorkspace)]

        fixture.controller.workspaceManager.setInteractionMonitor(fixture.rightMonitor.id)
        XCTAssertEqual(fixture.controller.workspaceManager.interactionMonitorId, fixture.rightMonitor.id)
        let right = try resolve("Browsers", fixture).get()
        XCTAssertEqual(right.scope, .activeWorkspace(fixture.rightWorkspace))
        XCTAssertEqual(right.members.map(\.token), [rightBrowser])

        fixture.controller.workspaceManager.setInteractionMonitor(fixture.leftMonitor.id)
        XCTAssertEqual(fixture.controller.workspaceManager.interactionMonitorId, fixture.leftMonitor.id)
        let left = try resolve("Browsers", fixture).get()
        XCTAssertEqual(left.scope, .activeWorkspace(fixture.leftWorkspace))
        XCTAssertEqual(left.members.map(\.token), [leftBrowser])
    }

    func testAllWorkspacesScopeIncludesInactiveWorkspaces() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.savedWindowGroups = [browsers(scope: .allWorkspaces)]

        let resolution = try resolve("Browsers", fixture).get()

        XCTAssertEqual(resolution.status, .resolved)
        XCTAssertEqual(resolution.members.map(\.token), [leftBrowser, rightBrowser, inactiveBrowser])
    }

    func testActiveWorkspaceWithoutAFocusedMonitorFailsWithoutFallback() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.savedWindowGroups = [browsers(scope: .activeWorkspace)]
        fixture.controller.workspaceManager.setInteractionMonitor(nil, preservePrevious: false)
        XCTAssertNil(fixture.controller.workspaceManager.interactionMonitorId)
        XCTAssertNil(fixture.controller.workspaceManager.nativeManagedFocusToken)

        XCTAssertEqual(resolve("Browsers", fixture).failure, .scopeUnavailable(.noFocusedMonitor))
    }

    func testLookupFailuresAreTyped() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.savedWindowGroups = [
            browsers(scope: .allWorkspaces),
            SavedWindowGroup(name: "Empty", scope: .allWorkspaces, include: [])
        ]

        XCTAssertEqual(resolve("Missing", fixture).failure, .unknownGroup)
        XCTAssertEqual(resolve("\t", fixture).failure, .invalidName)
        XCTAssertEqual(resolve("Empty", fixture).failure, .invalidDefinition([.emptyInclusions]))
        XCTAssertEqual(resolve("browsers", fixture).failure, .unknownGroup)
    }

    func testAppHiddenWindowsAreMembersAndStayHidden() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.savedWindowGroups = [browsers(scope: .allWorkspaces)]
        _ = fixture.controller.workspaceManager.setAppHidden(true, pid: leftBrowser.pid, source: .ax)

        let resolution = try resolve("Browsers", fixture).get()

        XCTAssertEqual(resolution.members.map(\.token), [leftBrowser, rightBrowser, inactiveBrowser])
        XCTAssertEqual(resolution.members.map(\.isAppHidden), [true, true, false])
        XCTAssertTrue(fixture.controller.workspaceManager.isAppHidden(pid: leftBrowser.pid))
    }

    func testScratchpadWindowsAreNotCandidates() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.savedWindowGroups = [browsers(scope: .allWorkspaces)]
        XCTAssertTrue(fixture.controller.workspaceManager.setScratchpadMembership(inactiveBrowser, to: 2))

        let resolution = try resolve("Browsers", fixture).get()

        XCTAssertEqual(resolution.members.map(\.token), [leftBrowser, rightBrowser])
        XCTAssertEqual(fixture.controller.workspaceManager.scratchpadIndex(for: inactiveBrowser), 2)
    }

    func testWindowRetiredDuringSnapshotIsReportedStale() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.savedWindowGroups = [
            SavedWindowGroup(
                name: "Docs",
                scope: .allWorkspaces,
                include: [SavedWindowGroupMatcher(bundleId: "com.example.browser", titleSubstring: "Doc")]
            )
        ]
        let controller = fixture.controller
        let reader = SavedWindowGroupSnapshotReader(
            applicationInfo: applicationInfo,
            windowFacts: { [rightBrowser] entry, _ in
                if entry.token == rightBrowser {
                    _ = controller.workspaceManager.removeWindow(pid: entry.token.pid, windowId: entry.token.windowId)
                }
                return Self.facts(title: "Doc")
            }
        )

        let resolution = try controller.resolveSavedWindowGroup(named: "Docs", reader: reader).get()

        XCTAssertEqual(resolution.status, .incomplete)
        XCTAssertEqual(resolution.members.map(\.token), [leftBrowser, inactiveBrowser])
        XCTAssertEqual(resolution.stale, [rightBrowser])
    }

    func testReplacementIsObservedOnlyThroughAFreshSnapshot() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.savedWindowGroups = [browsers(scope: .allWorkspaces)]
        let before = try resolve("Browsers", fixture).get()
        let replacementToken = WindowToken(pid: leftBrowser.pid, windowId: 91_199)

        _ = fixture.controller.axEventHandler.commitManagedWindowIdentityRebind(
            from: leftBrowser,
            to: replacementToken,
            axRef: WindowAdmissionTestSupport.axRef(for: replacementToken),
            managedReplacementMetadata: ManagedReplacementMetadata(
                bundleId: "com.example.browser",
                workspaceId: fixture.leftWorkspace,
                mode: .tiling,
                role: nil,
                subrole: nil,
                title: nil,
                windowLevel: nil,
                parentWindowId: nil,
                frame: nil
            )
        )

        XCTAssertEqual(before.members.map(\.token), [leftBrowser, rightBrowser, inactiveBrowser])
        let after = try resolve("Browsers", fixture).get()
        XCTAssertEqual(after.members.map(\.token), [rightBrowser, replacementToken, inactiveBrowser])
    }

    func testResolutionLeavesFocusVisibilityWorkspacesLayoutsAndMarksUnchanged() async throws {
        let fixture = try makeFixture()
        let controller = fixture.controller
        controller.settings.savedWindowGroups = [
            browsers(scope: .activeWorkspace),
            SavedWindowGroup(name: "All", scope: .allWorkspaces, include: [.init(bundleId: "com.example.editor")])
        ]
        XCTAssertTrue(controller.workspaceManager.setManagedFocus(
            rightEditor,
            in: fixture.rightWorkspace,
            onMonitor: fixture.rightMonitor.id
        ))
        _ = controller.workspaceManager.setAppHidden(true, pid: inactiveBrowser.pid, source: .ax)
        XCTAssertEqual(controller.windowMarkRegistry.set("Browsers", for: rightBrowser), .inserted)
        await WindowAdmissionTestSupport.drainLayoutRefreshes(controller)

        let worldSeq = controller.workspaceManager.worldSeq
        let marks = controller.windowMarkRegistry.marks
        let focus = controller.workspaceManager.nativeManagedFocusToken
        let workspaces = controller.workspaceManager.allEntries().map { [$0.token: $0.workspaceId] }
        let settingsBefore = controller.settings.toExport()

        XCTAssertEqual(try resolve("Browsers", fixture).get().members.map(\.token), [rightBrowser])
        XCTAssertEqual(try resolve("All", fixture).get().members.map(\.token), [rightEditor])
        XCTAssertEqual(resolve("Missing", fixture).failure, .unknownGroup)

        XCTAssertEqual(controller.workspaceManager.worldSeq, worldSeq)
        XCTAssertEqual(controller.windowMarkRegistry.marks, marks)
        XCTAssertEqual(controller.workspaceManager.nativeManagedFocusToken, focus)
        XCTAssertEqual(controller.workspaceManager.allEntries().map { [$0.token: $0.workspaceId] }, workspaces)
        XCTAssertTrue(controller.workspaceManager.isAppHidden(pid: inactiveBrowser.pid))
        XCTAssertEqual(controller.settings.toExport(), settingsBefore)
        let layoutState = controller.layoutRefreshController.layoutState
        XCTAssertNil(layoutState.activeRefresh)
        XCTAssertNil(layoutState.pendingRefresh)
    }

    private func browsers(scope: SavedWindowGroupScope) -> SavedWindowGroup {
        SavedWindowGroup(
            name: "Browsers",
            scope: scope,
            include: [SavedWindowGroupMatcher(bundleId: "com.example.browser")]
        )
    }

    private func resolve(
        _ name: String,
        _ fixture: Fixture
    ) -> Result<SavedWindowGroupResolution, SavedWindowGroupQueryFailure> {
        fixture.controller.resolveSavedWindowGroup(
            named: name,
            reader: SavedWindowGroupSnapshotReader(
                applicationInfo: applicationInfo,
                windowFacts: { _, _ in Self.facts(title: "Window") }
            )
        )
    }

    private func applicationInfo(_ pid: pid_t) -> AppInfoCache.AppInfo? {
        let bundleId = switch pid {
        case 91_001,
             91_002: "com.example.browser"
        case 91_003: "com.example.editor"
        default: nil as String?
        }
        return bundleId.map {
            AppInfoCache.AppInfo(name: $0, bundleId: $0, icon: nil, activationPolicy: .regular)
        }
    }

    private static func facts(title: String?) -> AXWindowFacts {
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

    private func makeFixture() throws -> Fixture {
        let leftFrame = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let rightFrame = CGRect(x: 1600, y: 0, width: 1600, height: 900)
        let leftMonitor = Monitor(
            id: .init(displayId: 917_001),
            displayId: 917_001,
            frame: leftFrame,
            visibleFrame: leftFrame,
            hasNotch: false,
            name: "Saved Group Left"
        )
        let rightMonitor = Monitor(
            id: .init(displayId: 917_002),
            displayId: 917_002,
            frame: rightFrame,
            visibleFrame: rightFrame,
            hasNotch: false,
            name: "Saved Group Right"
        )
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMSavedWindowGroupQuery")
        controller.settings.animationsEnabled = false
        controller.settings.workspaces.configurations = [
            WorkspaceConfiguration(
                name: "1",
                monitorAssignment: .specificDisplay(OutputId(from: leftMonitor)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "2",
                monitorAssignment: .specificDisplay(OutputId(from: rightMonitor)),
                layoutType: .niri
            ),
            WorkspaceConfiguration(
                name: "3",
                monitorAssignment: .specificDisplay(OutputId(from: rightMonitor)),
                layoutType: .dwindle
            )
        ]
        controller.workspaceManager.applyMonitorConfigurationChange([leftMonitor, rightMonitor])
        controller.workspaceManager.applySettings()
        let manager = controller.workspaceManager
        let leftWorkspace = try XCTUnwrap(manager.workspaceId(named: "1"))
        let rightWorkspace = try XCTUnwrap(manager.workspaceId(named: "2"))
        let inactiveRightWorkspace = try XCTUnwrap(manager.workspaceId(named: "3"))
        _ = manager.setActiveWorkspace(leftWorkspace, on: leftMonitor.id)
        _ = manager.setActiveWorkspace(rightWorkspace, on: rightMonitor.id)
        XCTAssertEqual(manager.activeWorkspace(on: leftMonitor.id)?.id, leftWorkspace)
        XCTAssertEqual(manager.activeWorkspace(on: rightMonitor.id)?.id, rightWorkspace)

        _ = WindowAdmissionTestSupport.track(leftBrowser, in: leftWorkspace, controller: controller)
        _ = WindowAdmissionTestSupport.track(rightBrowser, in: rightWorkspace, controller: controller)
        _ = WindowAdmissionTestSupport.track(inactiveBrowser, in: inactiveRightWorkspace, controller: controller)
        _ = WindowAdmissionTestSupport.track(rightEditor, in: rightWorkspace, controller: controller)

        return Fixture(
            controller: controller,
            leftMonitor: leftMonitor,
            rightMonitor: rightMonitor,
            leftWorkspace: leftWorkspace,
            rightWorkspace: rightWorkspace,
            inactiveRightWorkspace: inactiveRightWorkspace
        )
    }
}

private extension Result {
    var failure: Failure? {
        guard case let .failure(error) = self else { return nil }
        return error
    }
}
