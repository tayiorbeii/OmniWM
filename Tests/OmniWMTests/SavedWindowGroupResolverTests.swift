// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import AppKit
import Foundation
@testable import OmniWM
import XCTest

@MainActor
final class SavedWindowGroupResolverTests: XCTestCase {
    private let workspaceA = UUID(uuidString: "A0000000-0000-0000-0000-000000000001")!
    private let workspaceB = UUID(uuidString: "B0000000-0000-0000-0000-000000000002")!

    func testOneClauseReturnsEveryMatchingWindowInPidAndWindowOrder() throws {
        let group = try compiled(include: [.init(bundleId: "com.example.browser")])
        let snapshot = allWorkspaces([
            candidate(pid: 20, windowId: 3, bundleId: "com.example.browser"),
            candidate(pid: 10, windowId: 9, bundleId: "com.example.browser"),
            candidate(pid: 10, windowId: 2, bundleId: "com.example.browser"),
            candidate(pid: 30, windowId: 1, bundleId: "com.example.editor")
        ])

        let resolution = SavedWindowGroupResolver.resolve(group, in: snapshot)

        XCTAssertEqual(resolution.status, .resolved)
        XCTAssertEqual(resolution.members.map(\.token), [token(10, 2), token(10, 9), token(20, 3)])
        XCTAssertEqual(resolution.members.map(\.clauseIndex), [0, 0, 0])
        XCTAssertTrue(resolution.unresolved.isEmpty)
        XCTAssertTrue(resolution.stale.isEmpty)
    }

    func testCompleteSnapshotWithoutMatchesIsNoMatch() throws {
        let group = try compiled(include: [.init(bundleId: "com.example.absent")])
        let resolution = SavedWindowGroupResolver.resolve(group, in: allWorkspaces([
            candidate(pid: 1, windowId: 1, bundleId: "com.example.browser")
        ]))

        XCTAssertEqual(resolution.status, .noMatch)
        XCTAssertTrue(resolution.members.isEmpty)
        XCTAssertEqual(SavedWindowGroupResolver.resolve(group, in: allWorkspaces([])).status, .noMatch)
    }

    func testOverlappingInclusionsDeduplicateAndAttributeToEarliestClause() throws {
        let group = try compiled(include: [
            .init(bundleId: "com.example.editor"),
            .init(bundleId: "com.example.browser", titleSubstring: "Docs"),
            .init(bundleId: "com.example.browser")
        ])
        let snapshot = allWorkspaces([
            candidate(pid: 5, windowId: 1, bundleId: "com.example.browser", title: "Inbox"),
            candidate(pid: 4, windowId: 1, bundleId: "com.example.browser", title: "Docs home"),
            candidate(pid: 9, windowId: 1, bundleId: "com.example.editor")
        ])

        let resolution = SavedWindowGroupResolver.resolve(group, in: snapshot)

        XCTAssertEqual(resolution.status, .resolved)
        XCTAssertEqual(resolution.members.map(\.token), [token(9, 1), token(4, 1), token(5, 1)])
        XCTAssertEqual(resolution.members.map(\.clauseIndex), [0, 1, 2])
    }

    func testExclusionWinsRegardlessOfDeclarationOrder() throws {
        let group = try compiled(
            include: [.init(bundleId: "com.example.browser"), .init(bundleId: "com.example.browser")],
            exclude: [.init(bundleId: "com.example.browser", titleRegex: "^Private")]
        )
        let resolution = SavedWindowGroupResolver.resolve(group, in: allWorkspaces([
            candidate(pid: 1, windowId: 1, bundleId: "com.example.browser", title: "Private tab"),
            candidate(pid: 1, windowId: 2, bundleId: "com.example.browser", title: "Work")
        ]))

        XCTAssertEqual(resolution.status, .resolved)
        XCTAssertEqual(resolution.members.map(\.token), [token(1, 2)])
        XCTAssertTrue(resolution.unresolved.isEmpty)
    }

    func testCandidateEnumerationOrderDoesNotChangeTheResult() throws {
        let group = try compiled(
            include: [.init(bundleId: "com.example.b"), .init(bundleId: "com.example.a")],
            exclude: [.init(bundleId: "com.example.a", titleSubstring: "skip")]
        )
        let candidates = [
            candidate(pid: 3, windowId: 1, bundleId: "com.example.a", title: "keep"),
            candidate(pid: 1, windowId: 4, bundleId: "com.example.b", title: "x"),
            candidate(pid: 1, windowId: 2, bundleId: "com.example.a", title: "skip"),
            candidate(pid: 2, windowId: 2, bundleId: "com.example.b", title: "y"),
            candidate(pid: 2, windowId: 1, bundleId: "com.example.a", title: "keep too")
        ]
        let expected = SavedWindowGroupResolver.resolve(group, in: allWorkspaces(candidates))
        XCTAssertEqual(expected.members.map(\.token), [token(1, 4), token(2, 2), token(2, 1), token(3, 1)])

        for permutation in permutations(of: candidates) {
            XCTAssertEqual(SavedWindowGroupResolver.resolve(group, in: allWorkspaces(permutation)), expected)
        }
    }

    func testActiveWorkspaceScopeOnlyConsidersTheCapturedWorkspace() throws {
        let group = try compiled(scope: .activeWorkspace, include: [.init(bundleId: "com.example.browser")])
        let candidates = [
            candidate(pid: 1, windowId: 1, bundleId: "com.example.browser", workspace: workspaceA),
            candidate(pid: 1, windowId: 2, bundleId: "com.example.browser", workspace: workspaceB)
        ]

        let active = SavedWindowGroupResolver.resolve(group, in: SavedWindowGroupSnapshot(
            scope: .activeWorkspace(workspaceB),
            candidates: candidates,
            staleTokens: []
        ))
        XCTAssertEqual(active.scope, .activeWorkspace(workspaceB))
        XCTAssertEqual(active.members.map(\.token), [token(1, 2)])
        XCTAssertEqual(active.members.map(\.workspaceId), [workspaceB])

        let all = try SavedWindowGroupResolver.resolve(
            compiled(scope: .allWorkspaces, include: [.init(bundleId: "com.example.browser")]),
            in: allWorkspaces(candidates)
        )
        XCTAssertEqual(all.members.map(\.token), [token(1, 1), token(1, 2)])
    }

    func testTitleSelectsCurrentCandidatesInEachSnapshot() throws {
        let group = try compiled(include: [.init(bundleId: "com.example.editor", titleSubstring: "Report")])

        let before = SavedWindowGroupResolver.resolve(group, in: allWorkspaces([
            candidate(pid: 1, windowId: 1, bundleId: "com.example.editor", title: "Report.md")
        ]))
        let after = SavedWindowGroupResolver.resolve(group, in: allWorkspaces([
            candidate(pid: 1, windowId: 1, bundleId: "com.example.editor", title: "Notes.md")
        ]))

        XCTAssertEqual(before.members.map(\.token), [token(1, 1)])
        XCTAssertEqual(after.status, .noMatch)
    }

    func testFailedWindowReadOnlyAffectsClausesThatNeedWindowFacts() throws {
        let group = try compiled(include: [
            .init(bundleId: "com.example.editor", axRole: "AXWindow"),
            .init(bundleId: "com.example.browser")
        ])
        let resolution = SavedWindowGroupResolver.resolve(group, in: allWorkspaces([
            candidate(pid: 1, windowId: 1, bundleId: "com.example.browser", windowRead: .failed),
            candidate(pid: 2, windowId: 1, bundleId: "com.example.editor", windowRead: .failed)
        ]))

        XCTAssertEqual(resolution.status, .incomplete)
        XCTAssertEqual(resolution.members.map(\.token), [token(1, 1)])
        XCTAssertEqual(resolution.members.first?.unresolvedClauses, [])
        XCTAssertEqual(resolution.unresolved.map(\.token), [token(2, 1)])
        XCTAssertEqual(
            resolution.unresolved.first?.clauses,
            [.init(clause: .init(kind: .include, index: 0), facts: [.accessibilityRole])]
        )
    }

    func testMemberMatchedByOneClauseStaysWithUnknownClauseReported() throws {
        let group = try compiled(include: [
            .init(bundleId: "com.example.editor", titleSubstring: "Draft"),
            .init(bundleId: "com.example.editor", appNameSubstring: "Editor")
        ])
        let resolution = SavedWindowGroupResolver.resolve(group, in: allWorkspaces([
            candidate(pid: 1, windowId: 1, bundleId: "com.example.editor", appName: "Editor", title: nil)
        ]))

        XCTAssertEqual(resolution.status, .incomplete)
        XCTAssertEqual(resolution.members.map(\.token), [token(1, 1)])
        XCTAssertEqual(resolution.members.first?.clauseIndex, 1)
        XCTAssertEqual(
            resolution.members.first?.unresolvedClauses,
            [.init(clause: .init(kind: .include, index: 0), facts: [.title])]
        )
        XCTAssertTrue(resolution.unresolved.isEmpty)
    }

    func testDefiniteMismatchIsCompleteEvenWhenOtherFactsAreUnavailable() throws {
        let group = try compiled(include: [.init(bundleId: "com.example.editor", titleSubstring: "Draft")])
        let resolution = SavedWindowGroupResolver.resolve(group, in: allWorkspaces([
            candidate(pid: 1, windowId: 1, bundleId: "com.example.browser", windowRead: .failed),
            candidate(pid: 2, windowId: 1, application: .unavailable, title: "Notes")
        ]))

        XCTAssertEqual(resolution.status, .noMatch)
        XCTAssertTrue(resolution.unresolved.isEmpty)
    }

    func testUnavailableApplicationIdentityDiffersFromKnownAbsence() throws {
        let group = try compiled(include: [.init(bundleId: "com.example.editor")])

        let absent = SavedWindowGroupResolver.resolve(group, in: allWorkspaces([
            candidate(pid: 1, windowId: 1, application: .known(bundleId: nil, name: "Tool"))
        ]))
        XCTAssertEqual(absent.status, .noMatch)

        let unavailable = SavedWindowGroupResolver.resolve(group, in: allWorkspaces([
            candidate(pid: 1, windowId: 1, application: .unavailable)
        ]))
        XCTAssertEqual(unavailable.status, .incomplete)
        XCTAssertTrue(unavailable.members.isEmpty)
        XCTAssertEqual(
            unavailable.unresolved.first?.clauses,
            [.init(clause: .init(kind: .include, index: 0), facts: [.application])]
        )
    }

    func testKnownMissingRoleIsANonMatchButMissingTitleIsUnresolved() throws {
        let roleGroup = try compiled(include: [.init(bundleId: "com.example.editor", axRole: "AXWindow")])
        let roleResolution = SavedWindowGroupResolver.resolve(roleGroup, in: allWorkspaces([
            candidate(pid: 1, windowId: 1, bundleId: "com.example.editor", role: nil)
        ]))
        XCTAssertEqual(roleResolution.status, .noMatch)

        let titleGroup = try compiled(include: [.init(bundleId: "com.example.editor", titleRegex: ".")])
        let titleResolution = SavedWindowGroupResolver.resolve(titleGroup, in: allWorkspaces([
            candidate(pid: 1, windowId: 1, bundleId: "com.example.editor", title: nil)
        ]))
        XCTAssertEqual(titleResolution.status, .incomplete)
        XCTAssertEqual(titleResolution.unresolved.first?.clauses.first?.facts, [.title])
    }

    func testUnresolvedExclusionKeepsIncludedCandidateOutAndReportsIt() throws {
        let group = try compiled(
            include: [.init(bundleId: "com.example.browser")],
            exclude: [.init(bundleId: "com.example.browser", titleSubstring: "Private")]
        )
        let resolution = SavedWindowGroupResolver.resolve(group, in: allWorkspaces([
            candidate(pid: 1, windowId: 1, bundleId: "com.example.browser", windowRead: .failed),
            candidate(pid: 1, windowId: 2, bundleId: "com.example.browser", title: "Work")
        ]))

        XCTAssertEqual(resolution.status, .incomplete)
        XCTAssertEqual(resolution.members.map(\.token), [token(1, 2)])
        XCTAssertEqual(resolution.unresolved.map(\.token), [token(1, 1)])
        XCTAssertEqual(
            resolution.unresolved.first?.clauses,
            [.init(clause: .init(kind: .exclude, index: 0), facts: [.title])]
        )
    }

    func testMatchedExclusionWinsOverAnUnresolvedExclusion() throws {
        let group = try compiled(
            include: [.init(bundleId: "com.example.browser")],
            exclude: [
                .init(bundleId: "com.example.browser", titleSubstring: "Private"),
                .init(bundleId: "com.example.browser")
            ]
        )
        let resolution = SavedWindowGroupResolver.resolve(group, in: allWorkspaces([
            candidate(pid: 1, windowId: 1, bundleId: "com.example.browser", windowRead: .failed)
        ]))

        XCTAssertEqual(resolution.status, .noMatch)
        XCTAssertTrue(resolution.unresolved.isEmpty)
    }

    func testStaleCandidatesAreReportedWithoutStoppingResolution() throws {
        let group = try compiled(include: [.init(bundleId: "com.example.browser")])
        let resolution = SavedWindowGroupResolver.resolve(group, in: SavedWindowGroupSnapshot(
            scope: .allWorkspaces,
            candidates: [candidate(pid: 1, windowId: 2, bundleId: "com.example.browser")],
            staleTokens: [token(9, 9), token(1, 1)]
        ))

        XCTAssertEqual(resolution.status, .incomplete)
        XCTAssertEqual(resolution.members.map(\.token), [token(1, 2)])
        XCTAssertEqual(resolution.stale, [token(1, 1), token(9, 9)])
    }

    func testAppHiddenCandidatesAreMembersAndKeepTheirHiddenFlag() throws {
        let group = try compiled(include: [.init(bundleId: "com.example.browser")])
        let resolution = SavedWindowGroupResolver.resolve(group, in: allWorkspaces([
            candidate(pid: 1, windowId: 1, bundleId: "com.example.browser", isAppHidden: true)
        ]))

        XCTAssertEqual(resolution.status, .resolved)
        XCTAssertEqual(resolution.members.map(\.isAppHidden), [true])
    }

    func testCatalogReportsInvalidDefinitionsAndUnknownNames() {
        let duplicateID = UUID()
        let catalog = SavedWindowGroupCatalog(groups: [
            SavedWindowGroup(name: " Work ", scope: .allWorkspaces, include: [.init(bundleId: "a")]),
            SavedWindowGroup(name: "work", scope: .allWorkspaces, include: [.init(bundleId: "b")]),
            SavedWindowGroup(id: duplicateID, name: "Dup", scope: .allWorkspaces, include: [.init(bundleId: "a")]),
            SavedWindowGroup(id: duplicateID, name: "Dup", scope: .allWorkspaces, include: [.init(bundleId: "a")]),
            SavedWindowGroup(name: "Empty", scope: .activeWorkspace, include: []),
            SavedWindowGroup(
                name: "Broken",
                scope: .allWorkspaces,
                include: [.init(bundleId: "  ")],
                exclude: [.init(bundleId: "a", titleRegex: "(")]
            ),
            SavedWindowGroup(name: "bad\u{7}name", scope: .allWorkspaces, include: [.init(bundleId: "a")])
        ])

        XCTAssertEqual(catalog.entries.map(\.issues.isEmpty), [true, true, false, false, false, false, false])
        XCTAssertEqual(catalog.entries[2].issues, [.duplicateName, .duplicateID])
        XCTAssertEqual(catalog.entries[4].issues, [.emptyInclusions])
        XCTAssertEqual(catalog.entries[5].issues.first, .missingBundleId(.init(kind: .include, index: 0)))
        guard case let .invalidTitleRegex(clause, _)? = catalog.entries[5].issues.last else {
            return XCTFail("expected an invalid regex issue")
        }
        XCTAssertEqual(clause, .init(kind: .exclude, index: 0))
        XCTAssertEqual(catalog.entries[6].issues, [.invalidName])

        guard case let .valid(work) = catalog.lookup("Work") else { return XCTFail("Work must resolve") }
        XCTAssertEqual(work.group.name, " Work ")
        guard case let .valid(lowercase) = catalog.lookup("work") else { return XCTFail("work must resolve") }
        XCTAssertEqual(lowercase.group.name, "work")
        guard case let .invalid(_, issues) = catalog.lookup("Dup") else { return XCTFail("Dup must be invalid") }
        XCTAssertEqual(issues, [.duplicateName, .duplicateID])
        guard case .unknown = catalog.lookup("Missing") else { return XCTFail("Missing must be unknown") }
        guard case .invalidName = catalog.lookup(" \n ") else { return XCTFail("blank must be invalid") }
    }

    private enum WindowRead {
        case succeeded
        case failed
    }

    private func compiled(
        scope: SavedWindowGroupScope = .allWorkspaces,
        include: [SavedWindowGroupMatcher],
        exclude: [SavedWindowGroupMatcher] = []
    ) throws -> CompiledSavedWindowGroup {
        let group = SavedWindowGroup(name: "Group", scope: scope, include: include, exclude: exclude)
        guard case let .valid(compiled) = SavedWindowGroupCatalog(groups: [group]).lookup("Group") else {
            throw CocoaError(.validationMultipleErrors)
        }
        return compiled
    }

    private func allWorkspaces(_ candidates: [SavedWindowGroupCandidate]) -> SavedWindowGroupSnapshot {
        SavedWindowGroupSnapshot(scope: .allWorkspaces, candidates: candidates, staleTokens: [])
    }

    private func token(_ pid: pid_t, _ windowId: Int) -> WindowToken {
        WindowToken(pid: pid, windowId: windowId)
    }

    private func candidate(
        pid: pid_t,
        windowId: Int,
        bundleId: String,
        appName: String? = "App",
        title: String? = "Title",
        role: String? = "AXWindow",
        windowRead: WindowRead = .succeeded,
        workspace: WorkspaceDescriptor.ID? = nil,
        isAppHidden: Bool = false
    ) -> SavedWindowGroupCandidate {
        candidate(
            pid: pid,
            windowId: windowId,
            application: .known(bundleId: bundleId, name: appName),
            title: title,
            role: role,
            windowRead: windowRead,
            workspace: workspace,
            isAppHidden: isAppHidden
        )
    }

    private func candidate(
        pid: pid_t,
        windowId: Int,
        application: SavedWindowGroupCandidate.Application,
        title: String? = "Title",
        role: String? = "AXWindow",
        windowRead: WindowRead = .succeeded,
        workspace: WorkspaceDescriptor.ID? = nil,
        isAppHidden: Bool = false
    ) -> SavedWindowGroupCandidate {
        let succeeded = windowRead == .succeeded
        return SavedWindowGroupCandidate(
            token: token(pid, windowId),
            workspaceId: workspace ?? workspaceA,
            isAppHidden: isAppHidden,
            application: application,
            window: AXWindowFacts(
                role: succeeded ? role : nil,
                subrole: succeeded ? "AXStandardWindow" : nil,
                title: succeeded ? title : nil,
                hasCloseButton: false,
                hasFullscreenButton: false,
                fullscreenButtonEnabled: nil,
                hasZoomButton: false,
                hasMinimizeButton: false,
                appPolicy: .regular,
                bundleId: nil,
                attributeFetchSucceeded: succeeded
            )
        )
    }

    private func permutations<T>(of values: [T]) -> [[T]] {
        guard values.count > 1 else { return [values] }
        return values.indices.flatMap { index -> [[T]] in
            var rest = values
            let first = rest.remove(at: index)
            return permutations(of: rest).map { [first] + $0 }
        }
    }
}
