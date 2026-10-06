// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation
@testable import OmniWM
import TOML
import XCTest

final class SavedWindowGroupSettingsTests: XCTestCase {
    private let browsersID = UUID(uuidString: "6F1B5D0E-6A1F-4C0B-9D7E-0B5E2B9A1C01")!
    private let notesID = UUID(uuidString: "6F1B5D0E-6A1F-4C0B-9D7E-0B5E2B9A1C02")!

    private var sampleGroups: [SavedWindowGroup] {
        [
            SavedWindowGroup(
                id: browsersID,
                name: "Browsers",
                scope: .allWorkspaces,
                include: [
                    SavedWindowGroupMatcher(bundleId: "com.apple.Safari"),
                    SavedWindowGroupMatcher(bundleId: "org.mozilla.firefox", titleSubstring: "Docs")
                ],
                exclude: [SavedWindowGroupMatcher(bundleId: "com.apple.Safari", titleRegex: "^Private")]
            ),
            SavedWindowGroup(
                id: notesID,
                name: "Notes",
                scope: .activeWorkspace,
                include: [
                    SavedWindowGroupMatcher(
                        bundleId: "com.apple.Notes",
                        appNameSubstring: "Notes",
                        axRole: "AXWindow",
                        axSubrole: "AXStandardWindow"
                    )
                ]
            )
        ]
    }

    func testDefaultsHaveNoGroupsAndEncodeAnEmptyCurrentSchemaKey() throws {
        let export = SettingsExport.defaults()
        XCTAssertEqual(export.savedWindowGroups, [])

        let text = try String(decoding: SettingsTOMLCodec.encode(export), as: UTF8.self)
        XCTAssertTrue(text.contains("schemaVersion = 5"))
        XCTAssertTrue(text.contains("savedWindowGroups = []"))
    }

    func testGroupsRoundTripThroughCanonicalTOMLWithoutMigration() throws {
        var export = SettingsExport.defaults()
        export.savedWindowGroups = sampleGroups

        let data = try SettingsTOMLCodec.encode(export)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("[[savedWindowGroups]]"))
        XCTAssertTrue(text.contains("scope = \"allWorkspaces\""))
        XCTAssertTrue(text.contains("scope = \"activeWorkspace\""))

        let result = try SettingsTOMLCodec.decodeForLoad(data)
        XCTAssertNil(result.migration)
        XCTAssertEqual(result.export.savedWindowGroups, sampleGroups)
        XCTAssertEqual(result.export, export)
        XCTAssertEqual(SettingsTOMLCodec.unknownKeyPaths(in: data), [])
    }

    func testPersistedGroupsContainOnlyDefinitionKeys() throws {
        var export = SettingsExport.defaults()
        export.savedWindowGroups = sampleGroups
        let raw = try TOMLDecoder().decode([String: TOMLNode].self, from: SettingsTOMLCodec.encode(export))

        guard case let .array(groups)? = raw["savedWindowGroups"] else {
            return XCTFail("savedWindowGroups must encode as an array")
        }
        let allowedGroupKeys: Set<String> = ["id", "name", "scope", "include", "exclude"]
        let allowedMatcherKeys: Set<String> = [
            "bundleId", "appNameSubstring", "titleSubstring", "titleRegex", "axRole", "axSubrole"
        ]
        for group in groups {
            guard case let .table(table) = group else { return XCTFail("group must be a table") }
            XCTAssertTrue(Set(table.keys).isSubset(of: allowedGroupKeys), "\(table.keys)")
            for key in ["include", "exclude"] {
                guard case let .array(clauses)? = table[key] else { return XCTFail("\(key) must be an array") }
                for clause in clauses {
                    guard case let .table(clauseTable) = clause else { return XCTFail("clause must be a table") }
                    XCTAssertTrue(Set(clauseTable.keys).isSubset(of: allowedMatcherKeys), "\(clauseTable.keys)")
                }
            }
        }
    }

    func testVersionFourFileWithoutGroupsMigratesToAnEmptyGroupList() throws {
        let current = try String(decoding: SettingsTOMLCodec.encode(.defaults()), as: UTF8.self)
        let versionFour = current
            .replacingOccurrences(of: "schemaVersion = 5", with: "schemaVersion = 4")
            .replacingOccurrences(of: "savedWindowGroups = []\n", with: "")
        XCTAssertFalse(versionFour.contains("savedWindowGroups"))

        let result = try SettingsTOMLCodec.decodeForLoad(Data(versionFour.utf8))
        let migration = try XCTUnwrap(result.migration)

        XCTAssertEqual(migration.fromVersion, 4)
        XCTAssertEqual(migration.toVersion, 5)
        XCTAssertEqual(migration.defaultedPaths, ["savedWindowGroups"])
        XCTAssertEqual(result.export.savedWindowGroups, [])
        let migrated = String(decoding: try XCTUnwrap(result.migratedData), as: UTF8.self)
        XCTAssertTrue(migrated.contains("schemaVersion = 5"))
        XCTAssertTrue(migrated.contains("savedWindowGroups = []"))
    }

    func testCurrentSchemaRequiresExplicitScopeAndRejectsUnknownScope() throws {
        var export = SettingsExport.defaults()
        export.savedWindowGroups = [sampleGroups[0]]
        let text = try String(decoding: SettingsTOMLCodec.encode(export), as: UTF8.self)

        let missingScope = text.replacingOccurrences(of: "scope = \"allWorkspaces\"\n", with: "")
        XCTAssertNotEqual(missingScope, text)
        XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(missingScope.utf8)))

        let unknownScope = text.replacingOccurrences(
            of: "scope = \"allWorkspaces\"",
            with: "scope = \"focusedWindow\""
        )
        XCTAssertThrowsError(try SettingsTOMLCodec.decode(Data(unknownScope.utf8)))
    }

    func testOmittedExclusionsDecodeAsEmpty() throws {
        var export = SettingsExport.defaults()
        export.savedWindowGroups = [sampleGroups[1]]
        let text = try String(decoding: SettingsTOMLCodec.encode(export), as: UTF8.self)
        let withoutExclusions = text.replacingOccurrences(of: "exclude = []\n", with: "")
        XCTAssertNotEqual(withoutExclusions, text)

        let decoded = try SettingsTOMLCodec.decode(Data(withoutExclusions.utf8))
        XCTAssertEqual(decoded.savedWindowGroups, [sampleGroups[1]])
    }

    func testSemanticallyInvalidDefinitionsLoadAsAuthoredWithoutRejectingTheFile() throws {
        var export = SettingsExport.defaults()
        export.savedWindowGroups = [
            SavedWindowGroup(id: browsersID, name: " ", scope: .allWorkspaces, include: []),
            SavedWindowGroup(
                id: browsersID,
                name: "Broken",
                scope: .allWorkspaces,
                include: [SavedWindowGroupMatcher(bundleId: "", titleRegex: "(")]
            )
        ]

        let decoded = try SettingsTOMLCodec.decode(SettingsTOMLCodec.encode(export))
        XCTAssertEqual(decoded.savedWindowGroups, export.savedWindowGroups)
    }

    func testSavePreservesUnknownKeysInsideGroupsAndClauses() throws {
        var export = SettingsExport.defaults()
        export.savedWindowGroups = sampleGroups
        let canonical = try String(decoding: SettingsTOMLCodec.encode(export), as: UTF8.self)
        let previous = Data(canonical.replacingOccurrences(
            of: "name = \"Browsers\"\n",
            with: "futureGroupSetting = \"keep-me\"\nname = \"Browsers\"\n"
        ).utf8)
        XCTAssertEqual(SettingsTOMLCodec.unknownKeyPaths(in: previous), ["savedWindowGroups[0].futureGroupSetting"])

        var edited = try SettingsTOMLCodec.decode(previous)
        edited.savedWindowGroups.reverse()
        edited.savedWindowGroups[0].name = "Notebook"

        let rewritten = try SettingsTOMLCodec.encode(edited, preservingUnknownKeysFrom: previous)
        let raw = try TOMLDecoder().decode([String: TOMLNode].self, from: rewritten)
        guard case let .array(groups)? = raw["savedWindowGroups"],
              case let .table(first) = groups[0],
              case let .table(second) = groups[1]
        else {
            return XCTFail("savedWindowGroups must remain an array of tables")
        }
        XCTAssertNil(first["futureGroupSetting"])
        XCTAssertEqual(second["futureGroupSetting"], .string("keep-me"))
        XCTAssertEqual(try SettingsTOMLCodec.decode(rewritten).savedWindowGroups, edited.savedWindowGroups)
    }

    @MainActor
    func testSettingsStoreAppliesExportsAndPersistsGroups() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(
            persistence: SettingsFilePersistence(directory: directory, startWatching: false, deferSaves: false),
            runtimeState: RuntimeStateStore(directory: directory, deferSaves: false)
        )
        XCTAssertEqual(settings.savedWindowGroups, [])

        settings.savedWindowGroups = sampleGroups
        let saved = try SettingsTOMLCodec.decode(Data(contentsOf: settings.settingsFileURL))
        XCTAssertEqual(saved.savedWindowGroups, sampleGroups)

        var imported = settings.toExport()
        imported.savedWindowGroups = [sampleGroups[1]]
        settings.applyExport(imported)
        XCTAssertEqual(settings.savedWindowGroups, [sampleGroups[1]])
        XCTAssertEqual(settings.toExport().savedWindowGroups, [sampleGroups[1]])

        imported.savedWindowGroups = []
        settings.applyExport(imported)
        XCTAssertEqual(settings.savedWindowGroups, [])
        XCTAssertEqual(settings.toExport(), imported)
    }
}
