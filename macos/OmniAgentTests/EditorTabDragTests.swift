import XCTest
@testable import OmniAgent

/// Task 14: dragging an editor tab.
///
/// Two layers, tested two ways. The payload codec and the drop-zone geometry
/// are pure values and are asserted as such; the AppKit plumbing is driven
/// through the *real* views' `NSDraggingDestination` entry points with a stub
/// `NSDraggingInfo`, never through a private shortcut — a drop that AppKit
/// would refuse must be refused here too.
final class EditorTabDragTests: XCTestCase {
    // MARK: - The pure layer

    func testPayloadRoundTrip() {
        let payload = EditorTabDragPayload(paneID: "p1", index: 2)
        XCTAssertEqual(EditorTabDragPayload.decode(payload.pasteboardString()), payload)
        XCTAssertNil(EditorTabDragPayload.decode(nil))
        XCTAssertNil(EditorTabDragPayload.decode("junk"))
        XCTAssertNil(EditorTabDragPayload.decode(""))
    }

    func testZones() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 200, y: 100), in: bounds), .center)
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 50, y: 100), in: bounds), .insertBefore)
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 350, y: 100), in: bounds), .insertAfter)
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 200, y: 20), in: bounds), .insertBefore) // top (flipped)
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 200, y: 180), in: bounds), .insertAfter) // bottom
        // Corners: the horizontal edge wins (wider band).
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 10, y: 10), in: bounds), .insertBefore)
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 390, y: 10), in: bounds), .insertAfter)
    }

    /// The bands are proportions of `bounds`, and `bounds` is not always
    /// rooted at the origin — a pane's own coordinate space is, but nothing
    /// in the type says so.
    func testZonesAreRelativeToTheRectNotTheOrigin() {
        let bounds = CGRect(x: 1000, y: 500, width: 400, height: 200)
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 1200, y: 600), in: bounds), .center)
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 1050, y: 600), in: bounds), .insertBefore)
        XCTAssertEqual(EditorTabDropZone.zone(at: CGPoint(x: 1350, y: 600), in: bounds), .insertAfter)
    }

    /// A zero-size pane cannot have edges, and dividing by its width would be
    /// a NaN reaching the switch below it.
    func testDegenerateBoundsAreAlwaysCentre() {
        XCTAssertEqual(EditorTabDropZone.zone(at: .zero, in: .zero), .center)
        XCTAssertEqual(
            EditorTabDropZone.zone(at: .zero, in: CGRect(x: 0, y: 0, width: 100, height: 0)),
            .center
        )
    }

    // MARK: - The drag source

    /// Dragging a tab pins it (spec §4: "Double-click, editing the buffer, or
    /// dragging the tab pins it"), and what travels is only *which pane, which
    /// index* — the tab itself stays in the source model until a drop commits,
    /// so a cancelled drag changes nothing but that pin.
    func testDraggingATabPinsItAndCarriesItsPaneAndIndex() throws {
        let pane = makeEditorPane([tab("/a.swift", pinned: false), tab("/b.swift", pinned: false)])
        pane.paneID = "pane-1"

        let item = try XCTUnwrap(pane.makeTabDragItem(at: 1))
        let payload = try XCTUnwrap(
            EditorTabDragPayload.decode(item.string(forType: PaneWorkspaceView.editorTabDragType))
        )
        XCTAssertEqual(payload, EditorTabDragPayload(paneID: "pane-1", index: 1))
        XCTAssertTrue(pane.model.tabs[1].isPinned, "dragging a tab pins it")
        XCTAssertFalse(pane.model.tabs[0].isPinned, "and only that one")
        XCTAssertEqual(pane.model.tabs.count, 2, "the tab stays put until a drop commits")

        XCTAssertNil(pane.makeTabDragItem(at: 7), "there is no seventh tab")
        XCTAssertNil(pane.makeTabDragItem(at: -1))
    }

    // MARK: - The strip as a drop destination

    func testTheStripTakesADropAtTheIndexTheIndicatorShowed() throws {
        let pane = makeEditorPane([tab("/a.swift"), tab("/b.swift")])
        hostInWindow(pane)
        var received: (payload: EditorTabDragPayload, index: Int)?
        pane.onTabDroppedInStrip = { received = ($0, $1) }

        let frames = pane.strip.itemFrames
        XCTAssertEqual(frames.count, 2, "two tabs are laid out")
        let payload = EditorTabDragPayload(paneID: "other", index: 0)
        let info = stubInfo(payload, at: NSPoint(x: frames[1].midX + 1, y: frames[1].midY), in: pane.strip)

        XCTAssertEqual(pane.strip.draggingEntered(info), .move)
        XCTAssertTrue(pane.strip.performDragOperation(info))
        XCTAssertEqual(received?.payload, payload)
        XCTAssertEqual(received?.index, 2, "past both midpoints is the end of the strip")

        let leading = stubInfo(payload, at: NSPoint(x: frames[0].minX + 1, y: frames[0].midY), in: pane.strip)
        XCTAssertTrue(pane.strip.performDragOperation(leading))
        XCTAssertEqual(received?.index, 0)
    }

    func testTheStripRefusesAPasteboardWithoutATabPayload() {
        let pane = makeEditorPane([tab("/a.swift")])
        hostInWindow(pane)
        var fired = false
        pane.onTabDroppedInStrip = { _, _ in fired = true }

        let info = stubInfo(nil, at: .zero, in: pane.strip)
        XCTAssertEqual(pane.strip.draggingEntered(info), [])
        XCTAssertFalse(pane.strip.performDragOperation(info))
        XCTAssertFalse(fired, "a refused drop mutates nothing")
    }

    // MARK: - The pane container as a drop destination

    func testAnEditorPaneTakesTheDropAndReportsWhichZoneItLandedIn() throws {
        let workspace = makeWorkspace([.editor, .editor])
        var received: [(EditorTabDragPayload, String, EditorTabDropZone)] = []
        workspace.onEditorTabDropOnPane = { received.append(($0, $1, $2)) }
        let container = try XCTUnwrap(workspace.container(for: "pane-2"))
        let payload = EditorTabDragPayload(paneID: "pane-1", index: 0)
        let bounds = container.bounds

        for (point, expected) in [
            (NSPoint(x: bounds.midX, y: bounds.midY), EditorTabDropZone.center),
            (NSPoint(x: bounds.minX + 4, y: bounds.midY), .insertBefore),
            (NSPoint(x: bounds.maxX - 4, y: bounds.midY), .insertAfter),
            // The container is flipped, so minY is the *top* of the pane.
            (NSPoint(x: bounds.midX, y: bounds.minY + 4), .insertBefore),
            (NSPoint(x: bounds.midX, y: bounds.maxY - 4), .insertAfter),
        ] {
            let info = stubInfo(payload, at: point, in: container)
            XCTAssertEqual(container.draggingEntered(info), .move, "\(point)")
            XCTAssertTrue(container.performDragOperation(info), "\(point)")
            XCTAssertEqual(received.last?.0, payload)
            XCTAssertEqual(received.last?.1, "pane-2")
            XCTAssertEqual(received.last?.2, expected, "\(point)")
        }
    }

    func testTerminalAndBrowserPanesRefuseATabDropEverywhere() throws {
        let workspace = makeWorkspace([.editor, .terminal, .browser])
        var fired = false
        workspace.onEditorTabDropOnPane = { _, _, _ in fired = true }
        let payload = EditorTabDragPayload(paneID: "pane-1", index: 0)

        for id in ["pane-2", "pane-3"] {
            let container = try XCTUnwrap(workspace.container(for: id))
            for point in [
                NSPoint(x: container.bounds.midX, y: container.bounds.midY),
                NSPoint(x: container.bounds.minX + 4, y: container.bounds.midY),
            ] {
                let info = stubInfo(payload, at: point, in: container)
                XCTAssertEqual(container.draggingEntered(info), [], "\(id) shows the no-drop cursor")
                XCTAssertFalse(container.performDragOperation(info), "\(id)")
            }
        }
        XCTAssertFalse(fired, "a refused drop mutates nothing")
    }

    /// The cap is `PaneGrid.maxPanes`, and it bites only on the drops that
    /// would *create* a pane — moving a tab into a full pane's strip costs no
    /// grid cell at all.
    func testAFullGridRefusesAnEdgeDropButStillTakesACentreOne() throws {
        let workspace = makeWorkspace(
            [.editor] + Array(repeating: PaneKind.terminal, count: PaneGrid.maxPanes - 1)
        )
        XCTAssertEqual(workspace.paneIDs.count, PaneGrid.maxPanes)
        var received: [EditorTabDropZone] = []
        workspace.onEditorTabDropOnPane = { received.append($2) }
        let container = try XCTUnwrap(workspace.container(for: "pane-1"))
        let payload = EditorTabDragPayload(paneID: "pane-1", index: 0)

        let edge = stubInfo(payload, at: NSPoint(x: container.bounds.minX + 3, y: container.bounds.midY), in: container)
        XCTAssertEqual(container.draggingEntered(edge), [], "no room for the pane an edge drop inserts")
        XCTAssertFalse(container.performDragOperation(edge))
        XCTAssertTrue(received.isEmpty, "a refused drop mutates nothing")

        let centre = stubInfo(payload, at: NSPoint(x: container.bounds.midX, y: container.bounds.midY), in: container)
        XCTAssertEqual(container.draggingEntered(centre), .move, "a move into the strip needs no new cell")
        XCTAssertTrue(container.isDropTarget, "and it lights up")
        XCTAssertEqual(container.draggingUpdated(edge), [], "sliding back into the edge band refuses again")
        XCTAssertFalse(container.isDropTarget, "and drops the highlight with it")

        XCTAssertTrue(container.performDragOperation(centre))
        XCTAssertEqual(received, [.center])
    }

    // MARK: - The hole tile as a drop destination

    func testTheHoleTileTakesATabDrop() throws {
        let workspace = makeWorkspace([.editor, .editor, .editor])
        var received: EditorTabDragPayload?
        workspace.onEditorTabDropOnHole = { received = $0 }
        let hole = try XCTUnwrap(workspace.holePlaceholders.first, "3 panes on the 2x2 rung leave one hole")
        let payload = EditorTabDragPayload(paneID: "pane-1", index: 0)

        let info = stubInfo(payload, at: NSPoint(x: hole.bounds.midX, y: hole.bounds.midY), in: hole)
        XCTAssertEqual(hole.draggingEntered(info), .move)
        XCTAssertTrue(hole.performDragOperation(info))
        XCTAssertEqual(received, payload)

        let junk = stubInfo(nil, at: .zero, in: hole)
        received = nil
        XCTAssertEqual(hole.draggingEntered(junk), [])
        XCTAssertFalse(hole.performDragOperation(junk))
        XCTAssertNil(received)
    }

    // MARK: - Helpers

    private func tab(_ path: String, pinned: Bool = true) -> EditorTab {
        EditorTab(path: path, kind: .file, isPinned: pinned)
    }

    private func makeEditorPane(_ tabs: [EditorTab]) -> EditorPaneView {
        let pane = EditorPaneView(initialTabs: [], activeIndex: 0)
        pane.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        pane.modelForTesting { model in
            for (index, tab) in tabs.enumerated() { model.insert(tab, at: index) }
            model.activate(0)
        }
        pane.layoutSubtreeIfNeeded()
        return pane
    }

    /// A real window, so `convert(_:to: nil)` in the tests and
    /// `convert(_:from: nil)` in production share a defined base space.
    @discardableResult
    private func hostInWindow(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        // See `PaneWorkspaceViewTests.makeAttachedWorkspace`: the default
        // release-when-closed is an over-release with ARC still holding this.
        window.isReleasedWhenClosed = false
        window.contentView = view
        addTeardownBlock { window.close() }
        return window
    }

    private func makeWorkspace(_ kinds: [PaneKind]) -> PaneWorkspaceView {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-editor-tab-drag-test.sock")
        )
        let workspace = PaneWorkspaceView { descriptor in
            switch descriptor.kind {
            case .terminal:
                return TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
            case .browser:
                return BrowserPaneView(initialURL: descriptor.browserURL)
            case .editor:
                return EditorPaneView(
                    initialTabs: descriptor.editorTabs,
                    activeIndex: descriptor.editorActiveIndex
                )
            }
        }
        workspace.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        hostInWindow(workspace)
        for (index, kind) in kinds.enumerated() {
            XCTAssertTrue(workspace.addPane(
                PaneDescriptor(sessionID: "pane-\(index + 1)", group: "g", kind: kind)
            ))
        }
        workspace.layoutSubtreeIfNeeded()
        return workspace
    }

    /// `point` is in `view`'s own coordinates; `NSDraggingInfo` reports the
    /// window's, which is exactly what the destinations convert back.
    private func stubInfo(
        _ payload: EditorTabDragPayload?,
        at point: NSPoint,
        in view: NSView
    ) -> StubTabDraggingInfo {
        StubTabDraggingInfo(payload: payload, location: view.convert(point, to: nil))
    }
}

/// Minimal `NSDraggingInfo` carrying an editor-tab payload and a real
/// location, so the tests drive the production `NSDraggingDestination`
/// methods rather than a private shortcut.
final class StubTabDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint

    init(payload: EditorTabDragPayload?, location: NSPoint) {
        let pasteboard = NSPasteboard.withUniqueName()
        if let payload, let string = payload.pasteboardString() {
            pasteboard.declareTypes([PaneWorkspaceView.editorTabDragType], owner: nil)
            pasteboard.setString(string, forType: PaneWorkspaceView.editorTabDragType)
        } else {
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString("not a tab", forType: .string)
        }
        draggingPasteboard = pasteboard
        draggingLocation = location
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var numberOfValidItemsForDrop: Int = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
