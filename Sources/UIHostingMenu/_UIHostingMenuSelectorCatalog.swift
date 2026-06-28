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
        // contextMenuInteraction:configurationForMenuAtLocation: is unavailable.
        static let configurationMethodUnavailableDescription = string(["unavailable.", " is ", "Location:", "At", "Menu", "For", "configuration", "Interaction:", "Menu", "context"])
        // UIContextMenuConfiguration.actionProvider is missing.
        static let actionProviderMissingDescription = string(["missing.", " is ", "Provider", "action", ".", "Configuration", "Menu", "Context", "UI"])
        // Failed to build UIMenu from actionProvider.
        static let menuBuildFailedDescription = string(["Provider.", "action", " from ", "UIMenu", " build ", "to ", "Failed "])
        // com.apple.menu.dynamic.
        static let dynamicMenuIdentifierPrefix = string(["dynamic.", "menu.", "apple.", "com."])
    }

    enum InteractionRuntime {
        // _delegate_configurationForMenuAtLocation:
        static let delegateConfigurationForMenuAtLocation = selector(["Location:", "At", "Menu", "For", "configuration", "delegate_", "_"])
        // _delegate_contextMenuInteractionWillDisplayForConfiguration:
        static let delegateContextMenuInteractionWillDisplayForConfiguration = selector(["Configuration:", "For", "Display", "Will", "Interaction", "Menu", "context", "delegate_", "_"])
        // _delegate_contextMenuInteractionWillEndForConfiguration:presentation:
        static let delegateContextMenuInteractionWillEndForConfiguration = selector(["presentation:", "Configuration:", "For", "End", "Will", "Interaction", "Menu", "context", "delegate_", "_"])
        // _hasVisibleMenu
        static let hasVisibleMenu = selector(["Menu", "Visible", "has", "_"])
        // updateVisibleMenuWithBlock:
        static let updateVisibleMenuWithBlock = selector(["Block:", "With", "Menu", "Visible", "update"])
    }

    enum PresenterRuntime {
        // _contextMenuInteraction
        static let privateContextMenuInteraction = selector(["Interaction", "Menu", "context", "_"])
        // contextMenuInteraction
        static let contextMenuInteraction = selector(["Interaction", "Menu", "context"])
    }

    enum ActionRuntime {
        // sendAction:
        static let sendAction = selector(["Action:", "send"])
        // setHandler:
        static let setHandler = selector(["Handler:", "set"])
    }

    enum PresenterTesting {
        // _uihm_setMenu:
        static let setMenu = selector(["Menu:", "set", "_uihm_"])
        // _uihm_contextMenuInteraction:configurationForMenuAtLocation:
        static let configurationForMenuAtLocation = selector(["Location:", "At", "Menu", "For", "configuration", "Interaction:", "Menu", "context", "_uihm_"])
        // _uihm_contextMenuInteraction:previewForHighlightingMenuWithConfiguration:
        static let previewForHighlightingMenuWithConfiguration = selector(["Configuration:", "With", "Menu", "Highlighting", "For", "preview", "Interaction:", "Menu", "context", "_uihm_"])
        // _uihm_contextMenuInteraction:previewForDismissingMenuWithConfiguration:
        static let previewForDismissingMenuWithConfiguration = selector(["Configuration:", "With", "Menu", "Dismissing", "For", "preview", "Interaction:", "Menu", "context", "_uihm_"])
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

    enum DeferredRuntime {
        // presentationSourceItem
        static let presentationSourceItem = selector(["Item", "Source", "presentation"])
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

    // Keep runtime-coupled names split in compiled string literals.
    private static func string(_ reversedComponents: [String]) -> String {
        reversedComponents.reversed().joined()
    }

    private static func selector(_ reversedComponents: [String]) -> Selector {
        NSSelectorFromString(string(reversedComponents))
    }
}
