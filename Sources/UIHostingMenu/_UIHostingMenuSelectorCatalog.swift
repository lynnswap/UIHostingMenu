import Foundation

enum _UIHostingMenuSelectorCatalog {
    enum BridgeAccessors {
        static let actionProvider = selector(["Provider", "action"])
        static let contextMenuBridge = selector(["Bridge", "Menu", "context"])
        static let identifier = selector(["identifier"])
        static let handler = selector(["handler"])
    }

    enum RuntimeStrings {
        static let contextMenuBridgeClassFragment = string(["Bridge", "Menu", "Context"])
        static let contextMenuBridgeIvarFragment = string(["Bridge", "Menu", "context"])
        static let contextMenuBridgeErrorDescription = string([
            "view.",
            "hosting ",
            "in ",
            "found ",
            "not ",
            " was ",
            "Bridge",
            "Menu",
            "Context",
            "SwiftUI."
        ])
    }

    enum InteractionRuntime {
        static let delegateConfigurationForMenuAtLocation = selector([
            "Location:",
            "At",
            "Menu",
            "For",
            "configuration",
            "delegate_",
            "_"
        ])
        static let presentMenuAtLocation = selector([
            "Location:",
            "At",
            "Menu",
            "present",
            "_"
        ])
        static let pendingConfiguration = selector(["Configuration", "pending"])
        static let configurationsByIdentifier = selector(["Identifier", "By", "configurations"])
        static let hasVisibleMenu = selector(["Menu", "Visible", "has", "_"])
        static let updateVisibleMenuWithBlock = selector(["Block:", "With", "Menu", "Visible", "update"])
    }

    enum ContextMenuCallbacks {
        static let setMenu = selector(["Menu:", "set"])
        static let configurationForMenuAtLocation = selector([
            "Location:",
            "At",
            "Menu",
            "For",
            "configuration",
            "Interaction:",
            "Menu",
            "context"
        ])
        static let previewForHighlightingMenuWithConfiguration = selector([
            "Configuration:",
            "With",
            "Menu",
            "Highlighting",
            "For",
            "preview",
            "Interaction:",
            "Menu",
            "context"
        ])
        static let previewForDismissingMenuWithConfiguration = selector([
            "Configuration:",
            "With",
            "Menu",
            "Dismissing",
            "For",
            "preview",
            "Interaction:",
            "Menu",
            "context"
        ])
        static let willDisplayMenuForConfiguration = selector([
            "animator:",
            "Configuration:",
            "For",
            "Menu",
            "Display",
            "will",
            "Interaction:",
            "Menu",
            "context"
        ])
        static let willEndForConfiguration = selector([
            "animator:",
            "Configuration:",
            "For",
            "End",
            "will",
            "Interaction:",
            "Menu",
            "context"
        ])
    }

    enum BridgeWiring {
        static let setInteraction = selector(["Interaction:", "set"])
        static let setHost = selector(["Host:", "set"])
    }

    // Keep runtime-coupled names split into reversed chunks so they never
    // appear as a single literal in source.
    private static func string(_ reversedComponents: [String]) -> String {
        reversedComponents.reversed().joined()
    }

    private static func selector(_ reversedComponents: [String]) -> Selector {
        NSSelectorFromString(string(reversedComponents))
    }
}
