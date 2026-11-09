import AppKit

/// The chrome of the overlay's floating controls: Liquid Glass on macOS 26 and later, the popover material before.
@MainActor
enum Glass {
    /// Checks set this to build the macOS 14–15 controls on a newer system.
    static var legacy = false

    static var isLiquid: Bool {
        guard !legacy, #available(macOS 26.0, *) else { return false }
        return true
    }

    /// The visible surface of a card and the view its controls go in.
    static func surface(radius: CGFloat) -> (surface: NSView, content: NSView) {
        if !legacy, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.style = .regular
            let holder = NSView()
            holder.autoresizingMask = [.width, .height]
            glass.contentView = holder
            return (glass, holder)
        }
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        return (effect, effect)
    }

    /// A free-standing round icon button drawn as native glass; unchanged before macOS 26.
    static func circle(_ button: NSButton) {
        guard !legacy, #available(macOS 26.0, *) else { return }
        button.isBordered = true
        button.bezelStyle = .glass
        button.borderShape = .circle
    }

    /// A labelled button inside a glass surface: the system accessory-bar bezel, shown while the pointer is over it.
    static func inBar(_ button: NSButton) {
        guard isLiquid else { return }
        button.isBordered = true
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
    }

    /// A full-size layer of floating controls that clicks pass through wherever there is no control. On macOS 26 it
    /// renders its glass in one pass and blends pieces that come within `spacing` of each other.
    static func group(spacing: CGFloat) -> (group: NSView, content: NSView) {
        let content = PassThroughView()
        content.autoresizingMask = [.width, .height]
        if !legacy, #available(macOS 26.0, *) {
            let container = GlassGroup()
            container.spacing = spacing
            container.contentView = content
            container.autoresizingMask = [.width, .height]
            return (container, content)
        }
        return (content, content)
    }

    /// Whether `view` draws its chrome as native Liquid Glass: inside a glass effect view or as a glass bezel.
    static func isGlassBacked(_ view: NSView) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        if let button = view as? NSButton, button.isBordered, button.bezelStyle == .glass { return true }
        var current: NSView? = view
        while let candidate = current {
            if candidate is NSGlassEffectView { return true }
            current = candidate.superview
        }
        return view.subviews.contains { $0 is NSGlassEffectView }
    }
}

/// A view that only takes clicks meant for its subviews.
final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@available(macOS 26.0, *)
final class GlassGroup: NSGlassEffectContainerView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
