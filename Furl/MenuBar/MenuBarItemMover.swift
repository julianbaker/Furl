//
//  MenuBarItemMover.swift
//  Furl
//
//  Moves another app's menu bar item between its hidden and on-screen
//  positions using synthesized Command-drag mouse events. Ported from Ice's
//  proven MenuBarItemManager. Uses Accessibility (to post events into other
//  apps) and the PUBLIC CGWindowList for geometry — no private window-server
//  APIs and no Screen Recording. It never opens or activates an item.
//

import Cocoa

/// Moves another app's menu bar item via synthesized Cmd-drag events.
enum MenuBarItemMover {

    /// Everything needed to target a single menu bar item with synthetic events.
    struct Target {
        let windowID: CGWindowID
        let pid: pid_t
        /// Frame in CoreGraphics (top-left origin) screen coordinates.
        var frame: CGRect
    }

    enum Edge {
        case left   // place so the moved item's maxX == anchor.minX
        case right  // place so the moved item's minX == anchor.maxX
    }

    enum MoverError: Error {
        case invalidEventSource
        case eventCreationFailure
        case invalidCursorLocation
        case couldNotComplete
        case timeout
    }

    // MARK: Public API

    /// Moves `item` so one of its edges abuts `anchor`, hiding the cursor and
    /// restoring it afterward. Retries up to 5 times, waking the item between
    /// attempts, accepting only if the item's frame actually changed.
    @MainActor
    static func move(item: Target, toEdge edge: Edge, of anchor: Target) async throws {
        guard let cursorLocation = CGEvent(source: nil)?.location else {
            throw MoverError.invalidCursorLocation
        }
        let initialFrame = item.frame

        MouseCursor.freeze()
        MouseCursor.hide()
        defer {
            MouseCursor.warp(to: cursorLocation)
            MouseCursor.unfreeze()
            MouseCursor.show()
        }

        var working = item
        var lastError: Error = MoverError.couldNotComplete
        for attempt in 1...5 {
            do {
                try await moveOnce(item: working, toEdge: edge, of: anchor)
                guard let newFrame = liveFrame(for: working.windowID) else {
                    throw MoverError.couldNotComplete
                }
                if newFrame != initialFrame {
                    return
                }
                throw MoverError.couldNotComplete
            } catch {
                lastError = error
                if attempt < 5 {
                    try? await wakeUp(item: working)
                    if let refreshed = liveFrame(for: working.windowID) {
                        working.frame = refreshed
                    }
                }
            }
        }
        throw lastError
    }

    // MARK: Core move (single attempt)

    @MainActor
    private static func moveOnce(item: Target, toEdge edge: Edge, of anchor: Target) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw MoverError.invalidEventSource
        }

        // Start the drag at the item's own (off-screen) location. Ice grabbed
        // at a far corner (20_000, 20_000), but that x clamps to the right end
        // of the menu bar, so the window server opens a make-room gap there —
        // every on-screen item lurches left and eases back. Grabbing at the
        // item's real position keeps any make-room off-screen.
        let startPoint = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let endPoint: CGPoint = switch edge {
        case .left: CGPoint(x: anchor.frame.minX, y: anchor.frame.midY)
        case .right: CGPoint(x: anchor.frame.maxX, y: anchor.frame.midY)
        }
        let fallbackPoint = CGPoint(x: item.frame.midX, y: item.frame.midY)

        guard
            let mouseDown = makeEvent(.move(.leftMouseDown), location: startPoint, windowID: item.windowID, pid: item.pid, source: source),
            let mouseUp = makeEvent(.move(.leftMouseUp), location: endPoint, windowID: anchor.windowID, pid: item.pid, source: source),
            let fallback = makeEvent(.move(.leftMouseUp), location: fallbackPoint, windowID: item.windowID, pid: item.pid, source: source)
        else {
            throw MoverError.eventCreationFailure
        }

        try permitAllEvents()

        do {
            try await scromble(mouseDown, from: .pid(item.pid), to: .sessionEventTap, waitingForFrameChangeOf: item.windowID)
            try await scromble(mouseUp, from: .pid(item.pid), to: .sessionEventTap, waitingForFrameChangeOf: item.windowID)
        } catch {
            try? await postAndWaitToReceive(fallback, to: .sessionEventTap)
            throw error
        }
    }

    /// Plain click (Cmd-down/up, matching Ice) to wake an unresponsive item.
    @MainActor
    private static func wakeUp(item: Target) async throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw MoverError.invalidEventSource
        }
        guard let frame = liveFrame(for: item.windowID) else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)

        guard
            let down = makeEvent(.move(.leftMouseDown), location: center, windowID: item.windowID, pid: item.pid, source: source),
            let up = makeEvent(.move(.leftMouseUp), location: center, windowID: item.windowID, pid: item.pid, source: source)
        else {
            throw MoverError.eventCreationFailure
        }
        try await scromble(down, from: .pid(item.pid), to: .sessionEventTap)
        try await scromble(up, from: .pid(item.pid), to: .sessionEventTap)
    }

    // MARK: Geometry (public APIs only)

    /// The window's current bounds via the public window list (top-left origin).
    static func liveFrame(for windowID: CGWindowID) -> CGRect? {
        var values: [UnsafeRawPointer?] = [UnsafeRawPointer(bitPattern: UInt(windowID))]
        guard
            let array = CFArrayCreate(kCFAllocatorDefault, &values, 1, nil),
            let list = CGWindowListCreateDescriptionFromArray(array) as? [[CFString: CFTypeRef]],
            let dict = list.first,
            let boundsDict = dict[kCGWindowBounds] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: boundsDict)
        else {
            return nil
        }
        return frame
    }
}

// MARK: - Event construction (verbatim field setup from Ice)

extension MenuBarItemMover {
    enum ButtonState {
        case leftMouseDown, leftMouseUp, rightMouseDown, rightMouseUp
    }

    enum EventType {
        case move(ButtonState)

        var buttonState: ButtonState {
            switch self {
            case .move(let s): s
            }
        }
        var cgType: CGEventType {
            switch buttonState {
            case .leftMouseDown: .leftMouseDown
            case .leftMouseUp: .leftMouseUp
            case .rightMouseDown: .rightMouseDown
            case .rightMouseUp: .rightMouseUp
            }
        }
        /// The ONLY event that carries .maskCommand is the move's mouse-down.
        var flags: CGEventFlags {
            switch self {
            case .move(.leftMouseDown): .maskCommand
            default: []
            }
        }
        var button: CGMouseButton {
            switch buttonState {
            case .leftMouseDown, .leftMouseUp: .left
            case .rightMouseDown, .rightMouseUp: .right
            }
        }
    }

    static func makeEvent(
        _ type: EventType,
        location: CGPoint,
        windowID: CGWindowID,
        pid: pid_t,
        source: CGEventSource
    ) -> CGEvent? {
        guard let event = CGEvent(
            mouseEventSource: source,
            mouseType: type.cgType,
            mouseCursorPosition: location,
            mouseButton: type.button
        ) else {
            return nil
        }
        event.flags = type.flags

        let userData = Int64(bitPattern: UInt64(UInt(bitPattern: ObjectIdentifier(event))))
        let wid = Int64(windowID)
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        event.setIntegerValueField(.eventSourceUserData, value: userData)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: wid)
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: wid)
        event.setIntegerValueField(.privateWindowID, value: wid)
        return event
    }
}

extension CGEventField {
    /// Private field carrying the event's window identifier. (Ice: `CGEventField(rawValue: 0x33)!`)
    static let privateWindowID = CGEventField(rawValue: 0x33)! // swiftlint:disable:this force_unwrapping

    static let menuBarItemMatchFields: [CGEventField] = [
        .eventSourceUserData,
        .mouseEventWindowUnderMousePointer,
        .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
        .privateWindowID,
    ]
}

// MARK: - Posting / scromble / waiting (ported from Ice)

extension MenuBarItemMover {
    enum TapLocation {
        case sessionEventTap
        case pid(pid_t)

        var cgTap: CGEventTapLocation? {
            switch self {
            case .sessionEventTap: .cgSessionEventTap
            case .pid: nil
            }
        }
    }

    static func post(_ event: CGEvent, to location: TapLocation) {
        switch location {
        case .pid(let pid): event.postToPid(pid)
        case .sessionEventTap: event.post(tap: .cgSessionEventTap)
        }
    }

    static func permitAllEvents() throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw MoverError.invalidEventSource
        }
        let mask: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source.setLocalEventsFilterDuringSuppressionState(mask, state: .eventSuppressionStateRemoteMouseDrag)
        source.setLocalEventsFilterDuringSuppressionState(mask, state: .eventSuppressionStateSuppressionInterval)
        source.localEventsSuppressionInterval = 0
    }

    static func eventsMatch(_ a: CGEvent, _ b: CGEvent) -> Bool {
        for field in CGEventField.menuBarItemMatchFields where a.getIntegerValueField(field) != b.getIntegerValueField(field) {
            return false
        }
        return true
    }

    @MainActor
    static func postAndWaitToReceive(_ event: CGEvent, to location: TapLocation) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let tap = MoverEventTap(options: .listenOnly, location: location, types: [event.type]) { proxy, type, received in
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }
                guard eventsMatch(received, event), proxy.isEnabled else { return nil }
                proxy.disable()
                continuation.resume()
                return nil
            }
            tap.enable(timeout: .milliseconds(50)) {
                tap.disable()
                continuation.resume(throwing: MoverError.timeout)
            }
            post(event, to: location)
        }
    }

    /// Ice's "scromble": ping-pong the event between two tap locations via a null sentinel.
    @MainActor
    static func scromble(_ event: CGEvent, from first: TapLocation, to second: TapLocation) async throws {
        guard let nullEvent = CGEvent(source: nil) else {
            throw MoverError.eventCreationFailure
        }
        let nullUserData = Int64(bitPattern: UInt64(UInt(bitPattern: ObjectIdentifier(nullEvent))))
        nullEvent.setIntegerValueField(.eventSourceUserData, value: nullUserData)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var tap1: MoverEventTap?
            let tap2 = MoverEventTap(options: .listenOnly, location: second, types: [event.type]) { proxy, type, received in
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }
                guard eventsMatch(received, event), proxy.isEnabled else { return nil }
                proxy.disable()
                post(event, to: first)
                continuation.resume()
                return nil
            }
            tap1 = MoverEventTap(options: .defaultTap, location: first, types: [nullEvent.type]) { proxy, type, received in
                if type == .tapDisabledByUserInput || type == .tapDisabledByTimeout {
                    proxy.enable()
                    return nil
                }
                guard received.getIntegerValueField(.eventSourceUserData) == nullUserData else { return nil }
                proxy.disable()
                post(event, to: second)
                return nil
            }
            tap1?.enable()
            tap2.enable(timeout: .milliseconds(75)) {
                tap1?.disable()
                tap2.disable()
                continuation.resume(throwing: MoverError.timeout)
            }
            post(nullEvent, to: first)
        }
    }

    @MainActor
    static func scromble(_ event: CGEvent, from first: TapLocation, to second: TapLocation, waitingForFrameChangeOf windowID: CGWindowID) async throws {
        let before = liveFrame(for: windowID)
        try await scromble(event, from: first, to: second)
        guard let before else {
            try? await Task.sleep(for: .milliseconds(50))
            return
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(75))
        while ContinuousClock.now < deadline {
            if let f = liveFrame(for: windowID), f != before { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
}

// MARK: - MouseCursor

enum MouseCursor {
    static func hide() { _ = CGDisplayHideCursor(CGMainDisplayID()) }
    static func show() { _ = CGDisplayShowCursor(CGMainDisplayID()) }
    static func warp(to point: CGPoint) { _ = CGWarpMouseCursorPosition(point) }

    /// Detaches the visible cursor from mouse movement while synthetic events
    /// are posted. `CGDisplayHideCursor` only works for the frontmost app —
    /// Furl is a background agent, so without this the cursor visibly
    /// teleports to the synthetic event locations and back.
    static func freeze() { _ = CGAssociateMouseAndMouseCursorPosition(0) }
    static func unfreeze() { _ = CGAssociateMouseAndMouseCursorPosition(1) }
}

// MARK: - Minimal event tap (trimmed port of Ice's EventTap)

@MainActor
final class MoverEventTap {
    @MainActor
    struct Proxy {
        fileprivate let tap: MoverEventTap
        var isEnabled: Bool { tap.isEnabled }
        func enable() { tap.enable() }
        func disable() { tap.disable() }
    }

    private let runLoop = CFRunLoopGetCurrent()
    private let mode: CFRunLoopMode = .commonModes
    private let handler: (Proxy, CGEventType, CGEvent) -> CGEvent?
    private var machPort: CFMachPort?
    private var source: CFRunLoopSource?

    var isEnabled: Bool {
        guard let machPort else { return false }
        return CGEvent.tapIsEnabled(tap: machPort)
    }

    init(
        options: CGEventTapOptions,
        location: MenuBarItemMover.TapLocation,
        types: [CGEventType],
        handler: @escaping (Proxy, CGEventType, CGEvent) -> CGEvent?
    ) {
        self.handler = handler
        let mask: CGEventMask = types.reduce(into: 0) { $0 |= 1 << $1.rawValue }
        let info = Unmanaged.passUnretained(self).toOpaque()

        let port: CFMachPort? = switch location {
        case .pid(let pid):
            CGEvent.tapCreateForPid(pid: pid, place: .tailAppendEventTap, options: options, eventsOfInterest: mask, callback: moverTapCallback, userInfo: info)
        case .sessionEventTap:
            CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: options, eventsOfInterest: mask, callback: moverTapCallback, userInfo: info)
        }
        guard let port, let src = CFMachPortCreateRunLoopSource(nil, port, 0) else { return }
        self.machPort = port
        self.source = src
    }

    deinit {
        guard let machPort else { return }
        CFMachPortInvalidate(machPort)
    }

    func enable() {
        guard let machPort, let source else { return }
        CFRunLoopAddSource(runLoop, source, mode)
        CGEvent.tapEnable(tap: machPort, enable: true)
    }

    func enable(timeout: Duration, onTimeout: @escaping @MainActor () -> Void) {
        enable()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            if self?.isEnabled == true { onTimeout() }
        }
    }

    func disable() {
        guard let machPort, let source else { return }
        CGEvent.tapEnable(tap: machPort, enable: false)
        CFRunLoopRemoveSource(runLoop, source, mode)
    }

    fileprivate func perform(_ type: CGEventType, _ event: CGEvent) -> CGEvent? {
        handler(Proxy(tap: self), type, event)
    }
}

private func moverTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<MoverEventTap>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated {
        tap.perform(type, event).map(Unmanaged.passUnretained)
    }
}
