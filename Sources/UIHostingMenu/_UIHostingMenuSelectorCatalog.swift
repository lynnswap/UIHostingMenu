import Foundation

#if canImport(UIKit)
import UIKit

enum _UIHostingMenuSelectorCatalog {
    enum HostingView {
        static let render = string(["(updateDisplayList: Swift.Bool) -> ()", "Preferences", "For", "render"])
    }

    enum Coordinator {
        static let makeMenu = string(["()", "Menu", "make"])
        static let willShow = string(["(interaction:)", "Show", "Will", "menu"])
        static let willEnd = #selector(UIContextMenuInteractionDelegate.contextMenuInteraction(_:willEndFor:animator:))
        static let menuActionTriggered = selector(["Triggered:", "Action", "menu"])
    }

    enum RuntimeStrings {
        static let dynamicMenuIdentifierPrefix = string(["dynamic.", "menu.", "apple.", "com."])
    }

    enum InteractionRuntime {
        static let delegateConfigurationForMenuAtLocation = selector(["Location:", "At", "Menu", "For", "configuration", "delegate_", "_"])
        static let delegateContextMenuInteractionWillDisplayForConfiguration = selector(["Configuration:", "For", "Display", "Will", "Interaction", "Menu", "context", "delegate_", "_"])
        static let delegateContextMenuInteractionWillEndForConfiguration = selector(["presentation:", "Configuration:", "For", "End", "Will", "Interaction", "Menu", "context", "delegate_", "_"])
        static let updateVisibleMenuWithBlock = selector(["Block:", "With", "Menu", "Visible", "update"])
    }

    enum PresenterRuntime {
        static let privateContextMenuInteraction = selector(["Interaction", "Menu", "context", "_"])
        static let contextMenuInteraction = selector(["Interaction", "Menu", "context"])
    }

    enum DeferredRuntime {
        static let presentationSourceItem = selector(["Item", "Source", "presentation"])
    }

#if DEBUG
    enum BridgeAccessors {
        static let handler = selector(["handler"])
    }

    enum ActionRuntime {
        static let sendAction = selector(["Action:", "send"])
    }

    enum DeferredTesting {
        static let elementProviderIvar = string(["Provider", "element", "_"])
        static let providerBlock = selector(["Block", "provider", "_"])
    }
#endif

    // Keep runtime-coupled names split in compiled string literals.
    private static func string(_ reversedComponents: [String]) -> String {
        reversedComponents.reversed().joined()
    }

    private static func selector(_ reversedComponents: [String]) -> Selector {
        NSSelectorFromString(string(reversedComponents))
    }
}
#endif
