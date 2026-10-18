import SwiftUI
#if os(macOS)
import AppKit

typealias PlatformFont = NSFont
#else
import os
import UIKit

typealias PlatformFont = UIFont
#endif

/// What differs between the Mac and iPhone/iPad builds of the shared code.
enum Platform {
    #if os(macOS)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    /// "Mac", "iPhone" or "iPad", for "on this Mac" in explanations.
    static let deviceName: String = {
        #if os(macOS)
        return "Mac"
        #else
        // The model identifier ("iPad8,8"), readable from any thread unlike `UIDevice`.
        var model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        if model.isEmpty {
            var size = 0
            sysctlbyname("hw.machine", nil, &size, nil, 0)
            var machine = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname("hw.machine", &machine, &size, nil, 0)
            model = String(cString: machine)
        }
        return model.hasPrefix("iPad") ? "iPad" : "iPhone"
        #endif
    }()

    @MainActor static var reduceMotion: Bool {
        #if os(macOS)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        UIAccessibility.isReduceMotionEnabled
        #endif
    }

    /// Memory an on-device model can use before the system ends the app (iOS limits each app to part of the
    /// device's memory; a Mac pages instead).
    static var modelMemoryBudget: Int64 {
        #if os(macOS)
        .max
        #else
        let available = Int64(os_proc_available_memory())
        return available > 0 ? available : Int64(ProcessInfo.processInfo.physicalMemory / 2)
        #endif
    }

    /// Font families the user can choose for captions.
    static var fontFamilies: [String] {
        #if os(macOS)
        NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
        #else
        UIFont.familyNames.sorted()
        #endif
    }

    static func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

extension PlatformFont {
    /// The caption font: the system font, or a family, at a weight, optionally italic.
    static func caption(family: String, size: CGFloat, weight: PlatformFont.Weight, italic: Bool) -> PlatformFont {
        #if os(macOS)
        var font: NSFont
        if family.isEmpty {
            font = .systemFont(ofSize: size, weight: weight)
        } else {
            let descriptor = NSFontDescriptor(fontAttributes: [.family: family])
                .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
            font = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
        }
        if italic {
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
        }
        return font
        #else
        var font: UIFont
        if family.isEmpty {
            font = .systemFont(ofSize: size, weight: weight)
        } else {
            let descriptor = UIFontDescriptor(fontAttributes: [.family: family])
                .addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
            font = UIFont(descriptor: descriptor, size: size)
        }
        if italic, let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: descriptor, size: size)
        }
        return font
        #endif
    }
}
