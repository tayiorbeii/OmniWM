// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import OmniWMIPC
import XCTest

@MainActor
final class SavedWindowGroupRequestExecutorTests: XCTestCase {
    private let sessionToken = "saved-group-session"
    private let browserOne = WindowToken(pid: 93_001, windowId: 93_101)
    private let browserTwo = WindowToken(pid: 93_001, windowId: 93_102)
    private let editor = WindowToken(pid: 93_002, windowId: 93_103)

    func testListReportsEveryConfiguredGroupWithValidity() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.savedWindowGroups = [
            browsers(),
            SavedWindowGroup(name: "Empty", scope: .activeWorkspace, include: [], exclude: [.init(bundleId: "x")])
        ]

        let response = fixture.executor.response(for: .list, id: "list")

        XCTAssertTrue(response.ok)
        guard case let .windowGroups(payload)? = response.result?.payload else { return XCTFail("expected groups") }
        XCTAssertEqual(payload.groups.map(\.name), ["Browsers", "Empty"])
        XCTAssertEqual(payload.groups.map(\.scope), [.allWorkspaces, .activeWorkspace])
        XCTAssertEqual(payload.groups.map(\.isValid), [true, false])
        XCTAssertEqual(payload.groups.map(\.inclusionCount), [1, 0])
        XCTAssertEqual(payload.groups.map(\.exclusionCount), [1, 1])
    }

    func testInspectShowsDefinitionAndIssuesWithoutResolving() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.savedWindowGroups = [
            browsers(),
            SavedWindowGroup(name: "Broken", scope: .allWorkspaces, include: [.init(bundleId: "a", titleRegex: "(")])
        ]
        var reads = 0
        let executor = IPCWindowGroupRequestExecutor(
            controller: fixture.controller,
            sessionToken: sessionToken,
            reader: SavedWindowGroupSnapshotReader(
                applicationInfo: { _ in
                    reads += 1
                    return nil
                },
                windowFacts: { _, _ in
                    reads += 1
                    return Self.facts(title: nil)
                }
            )
        )

        let valid = executor.response(for: .inspect(name: "Browsers"), id: "inspect")
        guard case let .windowGroup(definition)? = valid.result?.payload else { return XCTFail("expected definition") }
        XCTAssertTrue(valid.ok)
        XCTAssertEqual(definition.include, [IPCWindowGroupMatcher(bundleId: "com.example.browser")])
        XCTAssertEqual(
            definition.exclude,
            [IPCWindowGroupMatcher(bundleId: "com.example.browser", titleRegex: "^Private")]
        )
        XCTAssertEqual(definition.issues, [])

        let broken = executor.response(for: .inspect(name: "Broken"), id: "inspect-broken")
        guard case let .windowGroup(brokenDefinition)? = broken.result?.payload else {
            return XCTFail("expected definition")
        }
        XCTAssertTrue(broken.ok)
        XCTAssertEqual(brokenDefinition.issues.map(\.code), [.invalidTitleRegex])
        XCTAssertEqual(brokenDefinition.issues.first?.clause, IPCWindowGroupClauseRef(kind: .include, index: 0))
        XCTAssertEqual(reads, 0)
    }

    func testResolveProjectsOrderedMembersWithSessionScopedIDs() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.savedWindowGroups = [browsers()]

        let response = fixture.executor.response(for: .resolve(name: "Browsers"), id: "resolve")

        XCTAssertTrue(response.ok)
        guard case let .windowGroupResolution(payload)? = response.result?.payload else {
            return XCTFail("expected resolution")
        }
        XCTAssertEqual(payload.status, .resolved)
        XCTAssertEqual(payload.scope, .allWorkspaces)
        XCTAssertNil(payload.workspace)
        XCTAssertEqual(payload.members.map(\.id), [browserOne, browserTwo].map(opaqueID))
        XCTAssertEqual(payload.members.map(\.matchedClause), [0, 0])
        XCTAssertEqual(payload.members.map(\.app?.bundleId), ["com.example.browser", "com.example.browser"])
        XCTAssertEqual(payload.members.map(\.workspace?.rawName), ["94", "94"])
        XCTAssertTrue(payload.unresolved.isEmpty)
        XCTAssertTrue(payload.stale.isEmpty)
    }

    func testResolveReportsNoMatchAndIncompleteResultsDistinctly() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.savedWindowGroups = [
            SavedWindowGroup(name: "Nothing", scope: .allWorkspaces, include: [.init(bundleId: "com.example.none")]),
            SavedWindowGroup(
                name: "Titled",
                scope: .allWorkspaces,
                include: [.init(bundleId: "com.example.editor", titleSubstring: "Draft")]
            )
        ]
        let executor = IPCWindowGroupRequestExecutor(
            controller: fixture.controller,
            sessionToken: sessionToken,
            reader: SavedWindowGroupSnapshotReader(
                applicationInfo: applicationInfo,
                windowFacts: { _, _ in Self.facts(title: nil) }
            )
        )

        guard case let .windowGroupResolution(nothing)? = executor.response(for: .resolve(name: "Nothing"), id: "1")
            .result?.payload
        else {
            return XCTFail("expected resolution")
        }
        XCTAssertEqual(nothing.status, .noMatch)

        guard case let .windowGroupResolution(titled)? = executor.response(for: .resolve(name: "Titled"), id: "2")
            .result?.payload
        else {
            return XCTFail("expected resolution")
        }
        XCTAssertEqual(titled.status, .incomplete)
        XCTAssertTrue(titled.members.isEmpty)
        XCTAssertEqual(titled.unresolved.map(\.id), [opaqueID(editor)])
        XCTAssertEqual(
            titled.unresolved.first?.unresolvedClauses,
            [IPCWindowGroupUnresolvedClause(clause: .init(kind: .include, index: 0), facts: [.title])]
        )
    }

    func testResolveFailuresAreTyped() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.savedWindowGroups = [
            SavedWindowGroup(
                name: "Active",
                scope: .activeWorkspace,
                include: [.init(bundleId: "com.example.browser")]
            ),
            SavedWindowGroup(name: "Broken", scope: .allWorkspaces, include: [.init(bundleId: " ")])
        ]
        fixture.controller.workspaceManager.setInteractionMonitor(nil, preservePrevious: false)

        XCTAssertEqual(fixture.executor.response(for: .resolve(name: "Missing"), id: "1").code, .unknownGroup)
        XCTAssertEqual(fixture.executor.response(for: .inspect(name: "Missing"), id: "2").code, .unknownGroup)
        XCTAssertEqual(fixture.executor.response(for: .resolve(name: "  "), id: "3").code, .invalidGroupName)

        let broken = fixture.executor.response(for: .resolve(name: "Broken"), id: "4")
        XCTAssertEqual(broken.code, .invalidGroup)
        guard case let .windowGroup(definition)? = broken.result?.payload else { return XCTFail("expected definition") }
        XCTAssertEqual(definition.issues.map(\.code), [.missingBundleId])

        let active = fixture.executor.response(for: .resolve(name: "Active"), id: "5")
        XCTAssertEqual(active.code, .groupScopeUnavailable)
        guard case let .windowGroup(activeDefinition)? = active.result?.payload else {
            return XCTFail("expected definition")
        }
        XCTAssertEqual(activeDefinition.scope, .activeWorkspace)
    }

    func testGroupAndMarkNamespacesStayIndependentOverIPC() throws {
        let fixture = try makeFixture()
        fixture.controller.settings.savedWindowGroups = [browsers()]
        XCTAssertEqual(fixture.controller.windowMarkRegistry.set("Browsers", for: editor), .inserted)
        XCTAssertEqual(fixture.controller.windowMarkRegistry.set("Editor", for: browserOne), .inserted)
        let marks = fixture.controller.windowMarkRegistry.marks

        guard case let .windowGroupResolution(payload)? = fixture.executor.response(
            for: .resolve(name: "Browsers"),
            id: "resolve"
        ).result?.payload else {
            return XCTFail("expected resolution")
        }
        XCTAssertEqual(payload.members.map(\.id), [browserOne, browserTwo].map(opaqueID))
        XCTAssertEqual(fixture.executor.response(for: .resolve(name: "Editor"), id: "mark").code, .unknownGroup)
        XCTAssertEqual(fixture.controller.windowMarkRegistry.marks, marks)
    }

    private struct Fixture {
        let controller: WMController
        let executor: IPCWindowGroupRequestExecutor
    }

    private func makeFixture() throws -> Fixture {
        let controller = WindowAdmissionTestSupport.controller(prefix: "OmniWMSavedWindowGroupExecutor")
        let workspaceId = try XCTUnwrap(
            WindowAdmissionTestSupport.workspace(named: "94", layoutType: .niri, controller: controller)
        )
        for token in [editor, browserTwo, browserOne] {
            _ = WindowAdmissionTestSupport.track(token, in: workspaceId, controller: controller)
        }
        let executor = IPCWindowGroupRequestExecutor(
            controller: controller,
            sessionToken: sessionToken,
            reader: SavedWindowGroupSnapshotReader(
                applicationInfo: applicationInfo,
                windowFacts: { _, _ in Self.facts(title: "Window") }
            )
        )
        return Fixture(controller: controller, executor: executor)
    }

    private func browsers() -> SavedWindowGroup {
        SavedWindowGroup(
            name: "Browsers",
            scope: .allWorkspaces,
            include: [.init(bundleId: "com.example.browser")],
            exclude: [.init(bundleId: "com.example.browser", titleRegex: "^Private")]
        )
    }

    private func opaqueID(_ token: WindowToken) -> String {
        IPCWindowOpaqueID.encode(token: token, sessionToken: sessionToken)
    }

    private func applicationInfo(_ pid: pid_t) -> AppInfoCache.AppInfo? {
        let bundleId = switch pid {
        case 93_001: "com.example.browser"
        case 93_002: "com.example.editor"
        default: nil as String?
        }
        return bundleId.map { AppInfoCache.AppInfo(name: $0, bundleId: $0, icon: nil, activationPolicy: .regular) }
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
}
