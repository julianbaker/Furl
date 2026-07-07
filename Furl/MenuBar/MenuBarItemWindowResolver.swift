//
//  MenuBarItemWindowResolver.swift
//  Furl
//
//  Resolves a menu bar item's CGWindowID from its on-screen position, using
//  only the PUBLIC CGWindowList. On modern macOS every menu bar extra is
//  composited by Control Center, so the item's window is owned by Control
//  Center (not the owning app) and must be matched by frame geometry rather
//  than by the app's pid. No private window-server APIs, and window geometry
//  does not require Screen Recording.
//

import Cocoa
import ApplicationServices

enum MenuBarItemWindowResolver {
    /// A resolved status-item window.
    struct Match {
        /// The window identifier (used to target synthetic events).
        let windowID: CGWindowID
        /// The window's real owner (Control Center, on modern macOS). Events
        /// must be posted to this pid, not the menu bar extra's app pid.
        let ownerPID: pid_t
        /// The window's bounds (CoreGraphics top-left origin).
        let frame: CGRect
    }

    /// A window observed in the public window list.
    struct WindowInfo {
        let windowID: CGWindowID
        let ownerPID: pid_t
        let layer: Int
        let frame: CGRect
    }

    /// Resolves the status-layer window whose frame best matches the item's
    /// Accessibility frame. Matched in BOTH axes: x identifies the item, and
    /// y identifies which display's copy of the item (each display's menu bar
    /// has its own window for the same item), so the menu bar is not assumed
    /// to sit at global y ≈ 0.
    static func resolve(axFrame: CGRect, toleranceX: CGFloat = 20, toleranceY: CGFloat = 40) -> Match? {
        // NOTE: do NOT use .optionOnScreenOnly — hidden menu bar items are
        // off-screen, and we specifically need to find those.
        guard let info = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: CFTypeRef]] else {
            return nil
        }

        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        var best: (match: Match, distance: CGFloat)?

        for dict in info {
            guard
                let layer = dict[kCGWindowLayer] as? Int,
                layer == statusLayer,
                let number = dict[kCGWindowNumber] as? CGWindowID,
                let owner = dict[kCGWindowOwnerPID] as? pid_t,
                let boundsDict = dict[kCGWindowBounds] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDict)
            else {
                continue
            }

            // Menu bar extra geometry: item-sized. This excludes status-level
            // popovers/panels (too tall) and the giant spacer/aggregate
            // windows (too wide).
            guard frame.height <= 40, frame.width <= 500 else {
                continue
            }

            let dx = abs(frame.minX - axFrame.minX)
            let dy = abs(frame.minY - axFrame.minY)
            guard dx <= toleranceX, dy <= toleranceY else {
                continue
            }
            let distance = dx + dy
            // swiftlint:disable:next force_unwrapping
            if best == nil || distance < best!.distance {
                best = (Match(windowID: number, ownerPID: owner, frame: frame), distance)
            }
        }
        return best?.match
    }

    /// Resolves our expanded divider — a very wide status-layer window. When
    /// `nearY` is given, prefers the copy in the same menu-bar band (each
    /// display has its own copy of the spacer); falls back to the widest.
    static func resolveSpacer(nearY: CGFloat? = nil) -> Match? {
        guard let info = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: CFTypeRef]] else {
            return nil
        }
        let statusLayer = Int(CGWindowLevelForKey(.statusWindow))
        var candidates = [Match]()
        for dict in info {
            guard
                let layer = dict[kCGWindowLayer] as? Int, layer == statusLayer,
                let number = dict[kCGWindowNumber] as? CGWindowID,
                let owner = dict[kCGWindowOwnerPID] as? pid_t,
                let boundsDict = dict[kCGWindowBounds] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDict)
            else {
                continue
            }
            guard frame.height <= 40, frame.width > 1000 else {
                continue
            }
            candidates.append(Match(windowID: number, ownerPID: owner, frame: frame))
        }
        if let nearY, let banded = candidates.filter({ abs($0.frame.minY - nearY) <= 40 }).max(by: { $0.frame.width < $1.frame.width }) {
            return banded
        }
        return candidates.max { $0.frame.width < $1.frame.width }
    }

    /// Every on-screen window (any owner), with owner, layer, and frame.
    /// Used to detect the window(s) an item opens: its app's own windows
    /// (popovers/panels) appear under its pid, while classic NSMenu menus do
    /// NOT — they only show up as new high-level windows near the item.
    static func onScreenWindows() -> [WindowInfo] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: CFTypeRef]] else {
            return []
        }
        var windows = [WindowInfo]()
        for dict in info {
            guard
                let number = dict[kCGWindowNumber] as? CGWindowID,
                let owner = dict[kCGWindowOwnerPID] as? pid_t,
                let layer = dict[kCGWindowLayer] as? Int,
                let boundsDict = dict[kCGWindowBounds] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: boundsDict)
            else {
                continue
            }
            windows.append(WindowInfo(windowID: number, ownerPID: owner, layer: layer, frame: frame))
        }
        return windows
    }

    /// The bounds of every active display (CoreGraphics top-left origin).
    static func activeDisplayBounds() -> [CGRect] {
        var displayCount: UInt32 = 0
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        guard
            CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount) == .success,
            displayCount > 0
        else {
            return [CGDisplayBounds(CGMainDisplayID())]
        }
        return (0..<Int(displayCount)).map { CGDisplayBounds(displayIDs[$0]) }
    }

    /// Whether the rect is visible on any active display.
    static func isOnAnyDisplay(_ rect: CGRect) -> Bool {
        activeDisplayBounds().contains { $0.intersects(rect) }
    }

    /// The AX frame (top-left origin) of the element, from kAXPosition + kAXSize.
    static func axFrame(of element: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let posValue, CFGetTypeID(posValue) == AXValueGetTypeID(),
            let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        // swiftlint:disable force_cast
        guard
            AXValueGetValue(posValue as! AXValue, .cgPoint, &point),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else {
            return nil
        }
        // swiftlint:enable force_cast
        return CGRect(origin: point, size: size)
    }
}
