import Foundation

enum _UIHostingMenuSelectorCatalog {
    enum BridgeAccessors {
        // actionProvider
        static let actionProvider = selector(["Provider", "action"])
        // contextMenuBridge
        static let contextMenuBridge = selector(["Bridge", "Menu", "context"])
        // identifier
        static let identifier = selector(["identifier"])
        // handler
        static let handler = selector(["handler"])
    }

    enum RuntimeStrings {
        // ContextMenuBridge
        static let contextMenuBridgeClassFragment = string(["Bridge", "Menu", "Context"])
        // contextMenuBridge
        static let contextMenuBridgeIvarFragment = string(["Bridge", "Menu", "context"])
        // SwiftUI.ContextMenuBridge was not found in hosting view.
        static let contextMenuBridgeErrorDescription = string(["view.", "hosting ", "in ", "found ", "not ", " was ", "Bridge", "Menu", "Context", "SwiftUI."])
    }

    enum InteractionRuntime {
        // _delegate_configurationForMenuAtLocation:
        static let delegateConfigurationForMenuAtLocation = selector(["Location:", "At", "Menu", "For", "configuration", "delegate_", "_"])
        // _hasVisibleMenu
        static let hasVisibleMenu = selector(["Menu", "Visible", "has", "_"])
        // updateVisibleMenuWithBlock:
        static let updateVisibleMenuWithBlock = selector(["Block:", "With", "Menu", "Visible", "update"])
    }

    enum DeferredTesting {
        // _elementProvider
        static let elementProviderIvar = string(["Provider", "element", "_"])
        // _providerBlock
        static let providerBlock = selector(["Block", "provider", "_"])
        // swiftUI_fulfilledElements
        static let swiftUIFulfilledElements = selector(["Elements", "fulfilled", "_", "UI", "swift"])
        // fulfilledElements
        static let fulfilledElements = selector(["Elements", "fulfilled"])
    }

    enum ContextMenuCallbacks {
        // setMenu:
        static let setMenu = selector(["Menu:", "set"])
        // contextMenuInteraction:configurationForMenuAtLocation:
        static let configurationForMenuAtLocation = selector(["Location:", "At", "Menu", "For", "configuration", "Interaction:", "Menu", "context"])
        // contextMenuInteraction:previewForHighlightingMenuWithConfiguration:
        static let previewForHighlightingMenuWithConfiguration = selector(["Configuration:", "With", "Menu", "Highlighting", "For", "preview", "Interaction:", "Menu", "context"])
        // contextMenuInteraction:previewForDismissingMenuWithConfiguration:
        static let previewForDismissingMenuWithConfiguration = selector(["Configuration:", "With", "Menu", "Dismissing", "For", "preview", "Interaction:", "Menu", "context"])
        // contextMenuInteraction:willDisplayMenuForConfiguration:animator:
        static let willDisplayMenuForConfiguration = selector(["animator:", "Configuration:", "For", "Menu", "Display", "will", "Interaction:", "Menu", "context"])
        // contextMenuInteraction:willEndForConfiguration:animator:
        static let willEndForConfiguration = selector(["animator:", "Configuration:", "For", "End", "will", "Interaction:", "Menu", "context"])
    }

    enum BridgeWiring {
        // setInteraction:
        static let setInteraction = selector(["Interaction:", "set"])
        // setHost:
        static let setHost = selector(["Host:", "set"])
    }

    // Keep runtime-coupled names split in compiled string literals. Comments
    // above each value show the reconstructed names for maintenance.
    private static func string(_ reversedComponents: [String]) -> String {
        reversedComponents.reversed().joined()
    }

    private static func selector(_ reversedComponents: [String]) -> Selector {
        NSSelectorFromString(string(reversedComponents))
    }
}
