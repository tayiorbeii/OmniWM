// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWMCtl
import OmniWMIPC
import XCTest

final class SavedWindowGroupIPCContractTests: XCTestCase {
    private enum TestFailure: Error {
        case unexpectedPayload
    }

    func testTypedWindowGroupRequestsRoundTripThroughTheIPCEnvelope() throws {
        let requests: [IPCWindowGroupRequest] = [.list, .inspect(name: "Browsers"), .resolve(name: "Work")]

        for (index, request) in requests.enumerated() {
            let envelope = IPCRequest(id: "group-\(index)", windowGroup: request)
            let decoded = try JSONDecoder().decode(IPCRequest.self, from: JSONEncoder().encode(envelope))
            XCTAssertEqual(decoded, envelope)
            XCTAssertEqual(decoded.kind, .windowGroup)
        }

        XCTAssertEqual(IPCRequestKind.windowGroup.rawValue, "window-group")
        XCTAssertEqual(IPCResponseKind(requestKind: .windowGroup), .windowGroup)
    }

    func testWindowGroupRequestWireShapeRequiresNamesExceptForList() throws {
        let resolve = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(IPCWindowGroupRequest.resolve(name: "Work"))
        ) as? [String: String]
        XCTAssertEqual(resolve, ["name": "resolve", "group": "Work"])
        let list = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(IPCWindowGroupRequest.list)
        ) as? [String: String]
        XCTAssertEqual(list, ["name": "list"])

        for invalid in [#"{"name":"inspect"}"#, #"{"name":"resolve"}"#, #"{"name":"list","group":"x"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(IPCWindowGroupRequest.self, from: Data(invalid.utf8)))
        }
    }

    func testParserBuildsGroupActionsWithoutMarkLookup() throws {
        let cases: [(arguments: [String], request: IPCWindowGroupRequest)] = [
            (["window", "group", "list"], .list),
            (["window", "group", "inspect", " Browsers "], .inspect(name: " Browsers ")),
            (["window", "group", "resolve", "Browsers"], .resolve(name: "Browsers"))
        ]
        for testCase in cases {
            let parsed = try CLIParser.parse(arguments: ["omniwmctl"] + testCase.arguments)
            guard case let .windowGroup(request) = parsed.request.payload else {
                throw TestFailure.unexpectedPayload
            }
            XCTAssertEqual(request, testCase.request)
        }

        let json = try CLIParser.parse(arguments: ["omniwmctl", "window", "group", "resolve", "Work", "--json"])
        XCTAssertEqual(json.outputFormat, .json)
        guard case .windowGroup(.resolve(name: "Work")) = json.request.payload else {
            throw TestFailure.unexpectedPayload
        }
    }

    func testParserRejectsMalformedAndActingGroupVerbs() {
        let invocations = [
            ["window", "group"],
            ["window", "group", "inspect"],
            ["window", "group", "resolve"],
            ["window", "group", "list", "extra"],
            ["window", "group", "resolve", "a", "b"],
            ["window", "group", "focus", "Work"],
            ["window", "group", "summon", "Work"],
            ["window", "group", "gather", "Work"]
        ]
        for invocation in invocations {
            XCTAssertThrowsError(try CLIParser.parse(arguments: ["omniwmctl"] + invocation)) { error in
                XCTAssertEqual(error as? CLIParseError, .usage(CLIParser.usageText))
            }
        }
    }

    func testManifestHelpAndAllShellCompletionsExposeOnlyReadOnlyGroupActions() {
        XCTAssertEqual(
            IPCAutomationManifest.windowGroupActionDescriptors.map(\.path),
            ["window group list [--json]", "window group inspect <name>", "window group resolve <name>"]
        )
        XCTAssertEqual(IPCWindowGroupActionName.allCases, [.list, .inspect, .resolve])
        for path in IPCAutomationManifest.windowGroupActionDescriptors.map(\.path) {
            XCTAssertTrue(CLIParser.usageText.contains("omniwmctl \(path)"))
        }
        XCTAssertTrue(CLICompletionCatalog.windowActionNames.contains("group"))
        XCTAssertEqual(CLICompletionCatalog.windowGroupActionNames, ["list", "inspect", "resolve"])

        for shell in CLIShell.allCases {
            let script = CLICompletionGenerator.script(for: shell)
            for token in ["group", "inspect", "resolve"] {
                XCTAssertTrue(script.contains(token), "\(shell.rawValue) completion missing \(token)")
            }
            XCTAssertFalse(script.contains("#{{"), "\(shell.rawValue) completion has an unfilled placeholder")
        }
    }

    func testResolutionRoundTripsAndRendersMembersAndDiagnostics() throws {
        let workspace = IPCWorkspaceRef(id: "workspace-1", rawName: "1", displayName: "Code", number: 1)
        let resolution = IPCWindowGroupResolution(
            id: "6F1B5D0E-6A1F-4C0B-9D7E-0B5E2B9A1C01",
            name: "Browsers",
            scope: .activeWorkspace,
            workspace: workspace,
            status: .incomplete,
            members: [
                IPCWindowGroupWindow(
                    id: "window-a",
                    workspace: workspace,
                    app: IPCAppRef(name: "Safari", bundleId: "com.apple.Safari"),
                    title: "Docs",
                    isAppHidden: true,
                    matchedClause: 1,
                    unresolvedClauses: [
                        IPCWindowGroupUnresolvedClause(
                            clause: IPCWindowGroupClauseRef(kind: .include, index: 0),
                            facts: [.title]
                        )
                    ]
                )
            ],
            unresolved: [
                IPCWindowGroupWindow(
                    id: "window-b",
                    workspace: workspace,
                    app: nil,
                    title: nil,
                    isAppHidden: false,
                    matchedClause: nil,
                    unresolvedClauses: [
                        IPCWindowGroupUnresolvedClause(
                            clause: IPCWindowGroupClauseRef(kind: .exclude, index: 0),
                            facts: [.accessibilityRole]
                        )
                    ]
                )
            ],
            stale: ["window-c"]
        )
        let response = IPCResponse.success(
            id: "resolve",
            kind: .windowGroup,
            result: IPCResult(windowGroupResolution: resolution)
        )
        let decoded = try JSONDecoder().decode(IPCResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(decoded, response)
        XCTAssertEqual(decoded.result?.kind, .windowGroupResolution)

        let text = try String(decoding: CLIRenderer.responseOutput(decoded, format: .table).data, as: UTF8.self)
        for expected in [
            "incomplete: 1 window(s) matched, 1 unresolved, 1 stale",
            "active-workspace Code",
            "window-a",
            "include[1]",
            "include[0]: title",
            "window-b",
            "exclude[0]: accessibility-role",
            "stale windows skipped: 1"
        ] {
            XCTAssertTrue(text.contains(expected), "missing \(expected) in\n\(text)")
        }

        let json = try JSONSerialization.jsonObject(
            with: CLIRenderer.responseOutput(decoded, format: .json).data
        ) as? [String: Any]
        let result = try XCTUnwrap(json?["result"] as? [String: Any])
        XCTAssertEqual(result["kind"] as? String, "window-group-resolution")
    }

    func testNoMatchAndInvalidDefinitionFailureRenderDistinctly() throws {
        let noMatch = IPCWindowGroupResolution(
            id: "id",
            name: "Empty",
            scope: .allWorkspaces,
            workspace: nil,
            status: .noMatch,
            members: [],
            unresolved: [],
            stale: []
        )
        let noMatchText = try String(
            decoding: CLIRenderer.responseOutput(
                .success(id: "1", kind: .windowGroup, result: IPCResult(windowGroupResolution: noMatch)),
                format: .text
            ).data,
            as: UTF8.self
        )
        XCTAssertTrue(noMatchText.contains("group Empty (all-workspaces): no matching windows"))

        let definition = IPCWindowGroupDefinition(
            id: "id",
            name: "Broken",
            scope: .allWorkspaces,
            include: [IPCWindowGroupMatcher(bundleId: "", titleRegex: "(")],
            exclude: [],
            issues: [
                IPCWindowGroupIssue(code: .missingBundleId, clause: IPCWindowGroupClauseRef(kind: .include, index: 0)),
                IPCWindowGroupIssue(
                    code: .invalidTitleRegex,
                    clause: IPCWindowGroupClauseRef(kind: .include, index: 0),
                    message: "bad pattern"
                )
            ]
        )
        let failure = IPCResponse.failure(
            id: "2",
            kind: .windowGroup,
            code: .invalidGroup,
            result: IPCResult(windowGroup: definition)
        )
        XCTAssertEqual(CLIRenderer.exitCode(for: failure), .rejected)
        let failureText = try String(decoding: CLIRenderer.responseOutput(failure, format: .text).data, as: UTF8.self)
        for expected in [
            "invalid_group",
            "invalid definition",
            "missing-bundle-id",
            "invalid-title-regex",
            "bad pattern"
        ] {
            XCTAssertTrue(failureText.contains(expected), "missing \(expected) in\n\(failureText)")
        }
    }

    func testTypedGroupCodesAreStableOnTheWire() {
        XCTAssertEqual(IPCErrorCode.invalidGroupName.rawValue, "invalid_group_name")
        XCTAssertEqual(IPCErrorCode.unknownGroup.rawValue, "unknown_group")
        XCTAssertEqual(IPCErrorCode.invalidGroup.rawValue, "invalid_group")
        XCTAssertEqual(IPCErrorCode.groupScopeUnavailable.rawValue, "group_scope_unavailable")
        XCTAssertEqual(IPCResultKind.windowGroups.rawValue, "window-groups")
        XCTAssertEqual(IPCResultKind.windowGroup.rawValue, "window-group")
        XCTAssertEqual(IPCResultKind.windowGroupResolution.rawValue, "window-group-resolution")
        XCTAssertEqual(IPCWindowGroupResolutionStatus.noMatch.rawValue, "no-match")
        XCTAssertEqual(IPCWindowGroupScope.activeWorkspace.rawValue, "active-workspace")
        XCTAssertEqual(IPCWindowGroupFact.accessibilityRole.rawValue, "accessibility-role")
    }
}
