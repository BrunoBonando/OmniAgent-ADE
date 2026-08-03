import XCTest
@testable import OmniAgent

/// The Swift half of the shared `fixtures/native-macos-compat/*.json`
/// contract.
///
/// Those fixtures exist so the same committed bytes are asserted from every
/// language that has to agree about them. Task 1 wired
/// `pane-grid.json` into both `ui/src/state/nativeMacosCompatibility.test.ts`
/// and `PaneGridTests.swift`, but the other three only ever got a
/// TypeScript or Rust consumer — a fixture nobody reads from this side is a
/// claim of parity nothing checks (final whole-branch review, Important #2).
/// This file adds the missing Swift side for all three, using
/// `PaneGridTests`' bundling mechanism (the JSON is a Resources build-phase
/// member of the test target, loaded by name out of the test bundle).
///
/// Where a fixture describes a Rust type this app has no counterpart for,
/// the assertion is about the *fields the native app does share* rather than
/// an invented mirror type — see each test's own comment. No new model types
/// are introduced here; that would defeat the point of a shared fixture.
final class NativeMacosCompatibilityFixtureTests: XCTestCase {
    // MARK: - Loading

    private func fixtureData(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle(for: NativeMacosCompatibilityFixtureTests.self)
                .url(forResource: name, withExtension: "json"),
            "fixtures/native-macos-compat/\(name).json is not bundled with the tests"
        )
        return try Data(contentsOf: url)
    }

    private func fixtureObject(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData(name)) as? [String: Any],
            "\(name).json is not a JSON object"
        )
    }

    private func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    /// Key-sorted JSON, for comparing two objects by *content* rather than by
    /// whatever order their encoder happened to emit (`JSONEncoder` and
    /// `JSONSerialization` do not agree on that, and neither promises one).
    private func canonicalJSON(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    // MARK: - persisted-layout.json

    /// The most consequential of the four: `layout` is one `settings` row in
    /// one `brain.db` that the native app and the web/Tauri app both read and
    /// write, so `PersistedLayoutCodec` and `deserializeLayout` have to agree
    /// byte-for-byte. `PersistedLayoutTests` covers the codec against
    /// hand-written Swift literals; this covers it against the *shared*
    /// committed bytes, mirroring what
    /// `ui/src/state/nativeMacosCompatibility.test.ts` asserts from the other
    /// side (same key, same clean round trip, same corrupt -> repaired
    /// mapping).
    func testPersistedLayoutFixtureRoundTripsAndRepairsExactlyLikeTheWebBuild() throws {
        let fixture = try fixtureObject("persisted-layout")

        XCTAssertEqual(
            SettingsKey.layout,
            fixture["setting_key"] as? String,
            "the native app must read/write the same settings row the web build does"
        )

        let layout = try XCTUnwrap(fixture["layout"] as? [String: Any])
        let expectedTabs = try XCTUnwrap(layout["tabs"] as? [[String: Any]])
        let restored = PersistedLayoutCodec.deserialize(try json(layout))
        XCTAssertEqual(
            restored,
            try expectedTabs.map(persistedTab),
            "a clean layout must survive deserialization unchanged"
        )

        let corrupt = try XCTUnwrap(fixture["corrupt_layout"] as? [String: Any])
        let repaired = try XCTUnwrap(fixture["repaired_layout"] as? [String: Any])
        let repairedTabs = try XCTUnwrap(repaired["tabs"] as? [[String: Any]])
        XCTAssertEqual(
            PersistedLayoutCodec.deserialize(try json(corrupt)),
            try repairedTabs.map(persistedTab),
            "the duplicate id, the bad themeId, the spaced group and the blank groupLabel "
                + "must each be dropped field-wise, never costing the tab"
        )

        // And back out again: what this app would *write* for the clean
        // layout has to be something both sides read back identically.
        XCTAssertEqual(
            PersistedLayoutCodec.deserialize(PersistedLayoutCodec.serialize(restored)),
            restored,
            "serialize -> deserialize must be a fixed point for the shared fixture"
        )
    }

    /// The fixture's JSON object for one tab, expressed as the Swift model.
    /// Deliberately built by hand from the raw dictionary rather than by
    /// calling `PersistedLayoutCodec.deserialize` — using the thing under
    /// test to build its own expectation would assert nothing.
    private func persistedTab(_ raw: [String: Any]) throws -> PersistedTab {
        PersistedTab(
            project: try XCTUnwrap(raw["project"] as? String),
            engine: try XCTUnwrap(Engine(rawValue: try XCTUnwrap(raw["engine"] as? String))),
            cwd: try XCTUnwrap(raw["cwd"] as? String),
            id: raw["id"] as? String,
            label: raw["label"] as? String,
            themeId: (raw["themeId"] as? String).flatMap(TerminalThemeId.init(rawValue:)),
            group: raw["group"] as? String,
            groupLabel: raw["groupLabel"] as? String
        )
    }

    // MARK: - status-end-events.json

    /// `status_events` is a *direct* shape match: `SessionStatusEvent`
    /// (`SessionConnection.swift`) is the native decoder for exactly the
    /// frames `src-tauri`'s `SessionStatusEvent` serializes, down to the
    /// `tool_execution`/`awaiting_approval` snake-case raw values, so it
    /// decodes the committed bytes and re-encodes to them.
    func testStatusEventFixtureDecodesAndReEncodesThroughSessionStatusEvent() throws {
        let fixture = try fixtureObject("status-end-events")
        let rawEvents = try XCTUnwrap(fixture["status_events"] as? [[String: Any]])
        let data = try JSONSerialization.data(withJSONObject: rawEvents)

        let events = try JSONDecoder().decode([SessionStatusEvent].self, from: data)
        XCTAssertEqual(
            events.map(\.status),
            [.ready, .thinking, .toolExecution, .awaitingApproval, .error],
            "every status the Rust side emits must decode to a known native case"
        )
        XCTAssertEqual(events.map(\.notify), [true, false, false, true, true])
        XCTAssertTrue(events.allSatisfy { $0.id == "sess-native-001" && $0.engine == "claude" })

        let reEncoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(events)
        ) as? [[String: Any]]
        XCTAssertEqual(
            try canonicalJSON(try XCTUnwrap(reEncoded)),
            try canonicalJSON(rawEvents),
            "a status event this app re-emits must carry exactly the fixture's fields and values"
        )
    }

    /// `session_end_event` is the *Tauri app's* `SessionEndEvent`
    /// (`{id, project, cwd, engine, transcript_path}` — the transcript-writing
    /// event `sessions.rs` raises), which has no native counterpart: this app
    /// talks to `omniagent-pty-daemon` directly and sees
    /// `SessionExitedEvent` (`{id, exit_code}`) instead. So rather than
    /// inventing a mirror type, this asserts the fields the two builds
    /// genuinely share about one ended session — the id shape both sides must
    /// accept, and an `engine` this app can actually render.
    func testSessionEndEventFixtureUsesIdentifiersAndAnEngineThisAppAccepts() throws {
        let fixture = try fixtureObject("status-end-events")
        let end = try XCTUnwrap(fixture["session_end_event"] as? [String: Any])
        let id = try XCTUnwrap(end["id"] as? String)

        XCTAssertTrue(
            SessionIdentifier.isValid(id),
            "a session id the Rust side mints must pass this app's own validation gate"
        )
        XCTAssertEqual(
            try XCTUnwrap(fixture["status_events"] as? [[String: Any]]).first?["id"] as? String,
            id,
            "the status and end fixtures describe the same session"
        )
        XCTAssertNotNil(
            Engine(rawValue: try XCTUnwrap(end["engine"] as? String)),
            "an engine the Rust side reports must be one this app can render"
        )
        XCTAssertNotNil(end["transcript_path"] as? String)

        // The daemon-side exit event this app *does* decode, keyed by the
        // same id, so the two views of "session ended" line up.
        let exited = try JSONDecoder().decode(
            SessionExitedEvent.self,
            from: try JSONSerialization.data(withJSONObject: ["id": id, "exit_code": 0])
        )
        XCTAssertEqual(exited.id, id)
        XCTAssertEqual(exited.exitCode, 0)
    }

    // MARK: - rust-session-models.json

    /// `create_session_request`/`session_info` are the *Tauri app's* session
    /// models (`{project, engine, cwd, briefing, restore_id}` /
    /// `{id, project, engine, cwd, created, restored, persistent}`). The
    /// native app's own `CreateSessionRequest` is a different thing entirely
    /// — the daemon's `{id, command, cwd, env, cols, rows, transcript_path}`
    /// — so there is no round trip to assert here and no honest way to
    /// manufacture one.
    ///
    /// What *is* a live shared contract: a session the Rust side describes has
    /// to be expressible as a `PersistedTab`, because that is what the
    /// `layout` row both apps share stores about it, and its `id` has to be
    /// replayable as a `restoreId`. That is what this checks, field by field.
    func testRustSessionModelFixtureMapsOntoTheLayoutRowThisAppPersists() throws {
        let fixture = try fixtureObject("rust-session-models")
        let request = try XCTUnwrap(fixture["create_session_request"] as? [String: Any])
        let info = try XCTUnwrap(fixture["session_info"] as? [String: Any])

        for model in [request, info] {
            XCTAssertNotNil(
                Engine(rawValue: try XCTUnwrap(model["engine"] as? String)),
                "engine must be one of this app's own AVAILABLE_AGENTS mirror"
            )
            XCTAssertFalse(try XCTUnwrap(model["project"] as? String).isEmpty)
            XCTAssertFalse(try XCTUnwrap(model["cwd"] as? String).isEmpty)
        }

        // `restore_id` is literally a `PersistedTab.id` handed back to the
        // backend, so it must pass the same gate the codec applies before
        // persisting one.
        let restoreID = try XCTUnwrap(request["restore_id"] as? String)
        XCTAssertTrue(SessionIdentifier.isValid(restoreID))
        XCTAssertEqual(restoreID, info["id"] as? String)
        XCTAssertEqual(try XCTUnwrap(info["restored"] as? Bool), true)

        let tab = PersistedTab(
            project: try XCTUnwrap(info["project"] as? String),
            engine: try XCTUnwrap(Engine(rawValue: try XCTUnwrap(info["engine"] as? String))),
            cwd: try XCTUnwrap(info["cwd"] as? String),
            id: try XCTUnwrap(info["id"] as? String)
        )
        XCTAssertEqual(
            PersistedLayoutCodec.deserialize(PersistedLayoutCodec.serialize([tab])),
            [tab],
            "a session the Rust side created must survive a native save/restore cycle"
        )
    }
}
