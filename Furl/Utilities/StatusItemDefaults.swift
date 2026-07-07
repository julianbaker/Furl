//
//  StatusItemDefaults.swift
//  Furl
//

import Cocoa

// MARK: - StatusItemDefaults

/// Proxy getters and setters for a status item's user defaults values.
enum StatusItemDefaults {
    /// Accesses the value associated with the specified key and autosave name.
    static subscript<Value>(key: Key<Value>, autosaveName: String) -> Value? {
        get {
            let stringKey = key.stringKey(for: autosaveName)
            return UserDefaults.standard.object(forKey: stringKey) as? Value
        }
        set {
            let stringKey = key.stringKey(for: autosaveName)
            return UserDefaults.standard.set(newValue, forKey: stringKey)
        }
    }
}

// MARK: - StatusItemDefaults.Key

extension StatusItemDefaults {
    /// Keys used to look up user defaults values for status items.
    struct Key<Value> {
        /// The raw value of the key.
        let rawValue: String

        /// Returns the full string key for the given autosave name.
        func stringKey(for autosaveName: String) -> String {
            return "NSStatusItem \(rawValue) \(autosaveName)"
        }
    }
}

extension StatusItemDefaults.Key<CGFloat> {
    /// String key: "NSStatusItem Preferred Position autosaveName"
    static let preferredPosition = Self(rawValue: "Preferred Position")
}
