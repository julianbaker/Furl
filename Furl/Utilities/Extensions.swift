//
//  Extensions.swift
//  Furl
//

import Cocoa

// MARK: - Bundle

extension Bundle {
    /// The bundle's copyright string.
    ///
    /// This accessor looks for an associated value for the "NSHumanReadableCopyright"
    /// key in the bundle's Info.plist. If a string value cannot be found for this key,
    /// this accessor returns `nil`.
    var copyrightString: String? {
        object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    }

    /// The bundle's version string.
    ///
    /// This accessor looks for an associated value for the "CFBundleShortVersionString"
    /// key in the bundle's Info.plist. If a string value cannot be found for this key,
    /// this accessor returns `nil`.
    var versionString: String? {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// The bundle's build string.
    ///
    /// This accessor looks for an associated value for the "CFBundleVersion" key in
    /// the bundle's Info.plist. If a string value cannot be found for this key, this
    /// accessor returns `nil`.
    var buildString: String? {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}

// MARK: - NSImage

extension NSImage {
    /// Returns a new image that has been resized to the given size.
    ///
    /// - Note: This method retains the ``isTemplate`` property.
    ///
    /// - Parameter size: The size to resize the current image to.
    func resized(to size: CGSize) -> NSImage {
        let resizedImage = NSImage(size: size, flipped: false) { bounds in
            self.draw(in: bounds)
            return true
        }
        resizedImage.isTemplate = isTemplate
        return resizedImage
    }
}

// MARK: - NSStatusItem

extension NSStatusItem {
    /// Shows the given menu under the status item.
    func showMenu(_ menu: NSMenu) {
        let originalMenu = self.menu
        defer {
            self.menu = originalMenu
        }
        self.menu = menu
        button?.performClick(nil)
    }
}
