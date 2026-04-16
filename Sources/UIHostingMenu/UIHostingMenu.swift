import Foundation
import ObjectiveC.runtime
import SwiftUI
import UIKit

public enum UIHostingMenuError: Swift.Error, LocalizedError {
    case contextMenuBridgeNotFound
    case configurationMethodUnavailable
    case configurationBuildFailed
    case actionProviderMissing
    case menuBuildFailed

    public var errorDescription: String? {
        switch self {
        case .contextMenuBridgeNotFound:
            return _UIHostingMenuSelectorCatalog.RuntimeStrings.contextMenuBridgeErrorDescription
        case .configurationMethodUnavailable:
            return "contextMenuInteraction:configurationForMenuAtLocation: is unavailable."
        case .configurationBuildFailed:
            return "Failed to create UIContextMenuConfiguration."
        case .actionProviderMissing:
            return "UIContextMenuConfiguration.actionProvider is missing."
        case .menuBuildFailed:
            return "Failed to build UIMenu from actionProvider."
        }
    }
}

@MainActor
private protocol _UIHostingMenuLiveMenuOwner: AnyObject {
    func _uiHostingMenuBuildMenuForLiveUpdate(at location: CGPoint) throws -> UIMenu
    func _uiHostingMenuProbeRootView() -> AnyView
}

@MainActor
private enum _UIHostingMenuAssociatedKeys {
    static var ownerTokenKey: UInt8 = 0
    static var liveCoordinatorKey: UInt8 = 0
    static var wrappedActionKey: UInt8 = 0
}

@MainActor
private final class _UIHostingMenuOwnerToken: NSObject {
    weak var owner: (any _UIHostingMenuLiveMenuOwner)?

    init(owner: any _UIHostingMenuLiveMenuOwner) {
        self.owner = owner
    }
}

/// iOS private API PoC.
/// - Notes:
///   - This mirrors NSHostingMenu's "rootView + cached result + update request" shape.
///   - Internally it calls SwiftUI.ContextMenuBridge through runtime selectors.
@MainActor
public final class UIHostingMenu<Content: View> {
    public typealias BuildError = UIHostingMenuError

    public var rootView: Content {
        didSet { setNeedsUpdate() }
    }

    public private(set) var cachedMenu: UIMenu?

    private var needsUpdate = true
    private var cachedLocation: CGPoint?
    private var invalidationTask: Task<Void, Never>?

    public init(rootView: Content) {
        self.rootView = rootView
    }

    public convenience init(@ViewBuilder menuItems: () -> Content) {
        self.init(rootView: menuItems())
    }

    deinit {
        invalidationTask?.cancel()
    }

    public func menu(at location: CGPoint = CGPoint(x: 0.5, y: 0.5)) throws -> UIMenu {
        if !needsUpdate,
           let cachedMenu,
           cachedLocation == location
        {
            return cachedMenu
        }

        let built = try _UIHostingMenuBridge.makeMenu(rootView: rootView, at: location)
        _UIHostingMenuLiveRuntime.activateIfNeeded()
        _UIHostingMenuLiveRuntime.associateOwnerToken(self, with: built)
        cachedMenu = built
        cachedLocation = location
        needsUpdate = false
        return built
    }

    public func updateRootView(_ rootView: Content) {
        self.rootView = rootView
    }

    public func setNeedsUpdate() {
        needsUpdate = true
        cachedMenu = nil
        cachedLocation = nil
    }

    public func requestUpdate(after delay: TimeInterval = 0) {
        invalidationTask?.cancel()
        guard delay > 0 else {
            setNeedsUpdate()
            return
        }

        invalidationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.setNeedsUpdate()
        }
    }
}

@MainActor
extension UIHostingMenu: _UIHostingMenuLiveMenuOwner {
    fileprivate func _uiHostingMenuBuildMenuForLiveUpdate(at location: CGPoint) throws -> UIMenu {
        setNeedsUpdate()
        let built = try menu(at: location)
        _UIHostingMenuLiveRuntime.associateOwnerToken(self, with: built)
        return built
    }

    fileprivate func _uiHostingMenuProbeRootView() -> AnyView {
        _UIHostingMenuBridge.makeProbeRootView(rootView: rootView)
    }
}

@MainActor
private enum _UIHostingMenuBridge {
    private static var retainedHostKey: UInt8 = 0

    static func makeProbeRootView<Content: View>(rootView: Content) -> AnyView {
        AnyView(_ContextMenuProbeView(menuItems: rootView))
    }

    static func makeMenu<Content: View>(
        rootView: Content,
        at location: CGPoint
    ) throws -> UIMenu {
        try makeMenuViaContextMenuBridge(rootView: rootView, at: location)
    }

    private static func makeMenuViaContextMenuBridge<Content: View>(
        rootView: Content,
        at location: CGPoint
    ) throws -> UIMenu {
        let wrapped = makeProbeRootView(rootView: rootView)

        let host = _MenuHost(rootView: wrapped)
        host.mountIfNeeded()
        defer { host.detachWindow() }

        let configuration = try host.makeConfiguration(at: location)
        guard let actionProvider = actionProvider(from: configuration) else {
            throw UIHostingMenuError.actionProviderMissing
        }
        guard let menu = actionProvider([]) else {
            throw UIHostingMenuError.menuBuildFailed
        }
        let normalizedMenu = normalizeInlineSectionsIfNeeded(menu)

        objc_setAssociatedObject(normalizedMenu, &retainedHostKey, host, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return normalizedMenu
    }

    private struct _ContextMenuProbeView<MenuItems: View>: View {
        let menuItems: MenuItems

        var body: some View {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: 120, height: 120)
                .contentShape(Rectangle())
                .contextMenu(menuItems: { menuItems })
        }
    }

    private static func actionProvider(
        from configuration: UIContextMenuConfiguration
    ) -> (([UIMenuElement]) -> UIMenu?)? {
        let selector = _UIHostingMenuSelectorCatalog.BridgeAccessors.actionProvider
        guard configuration.responds(to: selector),
              let method = class_getInstanceMethod(type(of: configuration), selector)
        else {
            return nil
        }

        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        typealias Provider = @convention(block) ([UIMenuElement]) -> UIMenu?

        let implementation = method_getImplementation(method)
        let getter = unsafeBitCast(implementation, to: Getter.self)
        guard let rawBlock = getter(configuration, selector) else {
            return nil
        }
        let provider = unsafeBitCast(rawBlock, to: Provider.self)
        return { suggested in provider(suggested) }
    }

    static func normalizeInlineSectionsIfNeeded(_ menu: UIMenu) -> UIMenu {
        let transformedChildren = normalizeInlineChildren(menu.children)
        guard transformedChildren.count != menu.children.count
            || !transformedChildren.elementsEqual(menu.children, by: { $0 === $1 })
        else {
            return menu
        }

        return UIMenu(
            title: menu.title,
            subtitle: menu.subtitle,
            image: menu.image,
            identifier: menu.identifier,
            options: menu.options,
            preferredElementSize: menu.preferredElementSize,
            children: transformedChildren
        )
    }

    private static func normalizeInlineChildren(_ children: [UIMenuElement]) -> [UIMenuElement] {
        var rebuilt = [UIMenuElement]()
        var pending = [UIMenuElement]()
        var sawInlineSection = false

        for child in children {
            let normalizedChild: UIMenuElement
            if let submenu = child as? UIMenu {
                normalizedChild = normalizeInlineSectionsIfNeeded(submenu)
            } else {
                normalizedChild = child
            }

            if let inlineMenu = normalizedChild as? UIMenu, inlineMenu.options.contains(.displayInline) {
                sawInlineSection = true
                if !pending.isEmpty {
                    rebuilt.append(UIMenu(options: .displayInline, children: pending))
                    pending.removeAll(keepingCapacity: true)
                }
                rebuilt.append(inlineMenu)
                continue
            }
            pending.append(normalizedChild)
        }

        if !pending.isEmpty {
            if sawInlineSection {
                rebuilt.append(UIMenu(options: .displayInline, children: pending))
            } else {
                rebuilt.append(contentsOf: pending)
            }
        }
        return rebuilt
    }
}

@MainActor
private final class _MenuHost: NSObject {
    private final class _FallbackContextMenuDelegate: NSObject, UIContextMenuInteractionDelegate {
        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            nil
        }
    }

    private let hostingController: UIHostingController<AnyView>
    private let containerController = UIViewController()
    private var window: UIWindow?
    private var didMount = false
    private let fallbackDelegate = _FallbackContextMenuDelegate()
    private lazy var fallbackInteraction = UIContextMenuInteraction(delegate: fallbackDelegate)

    init(rootView: AnyView) {
        self.hostingController = UIHostingController(rootView: rootView)
        super.init()
    }

    func updateRootView(_ rootView: AnyView) {
        hostingController.rootView = rootView
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
    }

    func mountIfNeeded() {
        guard !didMount else { return }
        didMount = true

        containerController.view.backgroundColor = .clear
        hostingController.loadViewIfNeeded()

        containerController.addChild(hostingController)
        containerController.view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: containerController.view.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: containerController.view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: containerController.view.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: containerController.view.bottomAnchor)
        ])
        hostingController.didMove(toParent: containerController)

        let windowFrame = CGRect(x: -4096, y: -4096, width: 240, height: 240)
        let window: UIWindow
        if let scene = Self.pickWindowScene() {
            window = UIWindow(windowScene: scene)
        } else {
            // XCTest / preview environments can have no connected UIWindowScene.
            // Use a standalone UIWindow so SwiftUI still installs context menu bridges.
            window = UIWindow(frame: windowFrame)
        }
        window.frame = windowFrame
        window.rootViewController = containerController
        window.backgroundColor = .clear
        window.alpha = 1.0
        window.isHidden = false
        containerController.view.frame = window.bounds
        hostingController.view.frame = containerController.view.bounds
        containerController.view.layoutIfNeeded()
        hostingController.view.layoutIfNeeded()
        self.window = window
    }

    func detachWindow() {
        guard let window else { return }
        window.isHidden = true
        window.rootViewController = nil
        self.window = nil
    }

    func makeConfiguration(at location: CGPoint) throws -> UIContextMenuConfiguration {
        try makeConfiguration(at: location, preferredInteraction: nil)
    }

    func makeConfiguration(
        at location: CGPoint,
        preferredInteraction: UIContextMenuInteraction?
    ) throws -> UIContextMenuConfiguration {
        if let bridge = bridgeAfterDeferredInstallationIfNeeded() {
            let interaction = interaction(for: bridge, preferredInteraction: preferredInteraction)
            if let configuration = configuration(from: bridge, interaction: interaction, at: location) {
                return configuration
            }
            if let fallbackInteraction = fallbackInteractionForConfiguration(preferredInteraction: preferredInteraction) {
                if let configuration = configuration(from: fallbackInteraction, at: location) {
                    return configuration
                }
                if let explored = configurationBySearchingLocation(in: fallbackInteraction) {
                    return explored
                }
            }
#if DEBUG
            debugBridgeDiagnostics()
#endif
            throw UIHostingMenuError.configurationBuildFailed
        }

        let interaction = preferredInteraction ?? interactionAfterDeferredInstallationIfNeeded()
        if let interaction {
            if let configuration = configuration(from: interaction, at: location) {
                return configuration
            }
            if let explored = configurationBySearchingLocation(in: interaction) {
                return explored
            }
#if DEBUG
            debugBridgeDiagnostics()
#endif
            throw UIHostingMenuError.configurationBuildFailed
        }

#if DEBUG
        debugBridgeDiagnostics()
#endif
        throw UIHostingMenuError.contextMenuBridgeNotFound
    }

    func notifyBridgeWillDisplay(
        interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration
    ) {
        guard let bridge = findAnyContextMenuBridge() else { return }
        let selector = _UIHostingMenuSelectorCatalog.ContextMenuCallbacks.willDisplayMenuForConfiguration
        guard bridge.responds(to: selector),
              let method = class_getInstanceMethod(type(of: bridge), selector)
        else {
            return
        }
        typealias Function = @convention(c) (AnyObject, Selector, UIContextMenuInteraction, UIContextMenuConfiguration, AnyObject?) -> Void
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        function(bridge, selector, interaction, configuration, nil)
    }

    func notifyBridgeWillEnd(
        interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration
    ) {
        guard let bridge = findAnyContextMenuBridge() else { return }
        let selector = _UIHostingMenuSelectorCatalog.ContextMenuCallbacks.willEndForConfiguration
        guard bridge.responds(to: selector),
              let method = class_getInstanceMethod(type(of: bridge), selector)
        else {
            return
        }
        typealias Function = @convention(c) (AnyObject, Selector, UIContextMenuInteraction, UIContextMenuConfiguration, AnyObject?) -> Void
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        function(bridge, selector, interaction, configuration, nil)
    }

    private func findContextMenuBridge(from root: Any) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        return firstObject(in: root, visited: &visited) { object in
            NSStringFromClass(type(of: object)).contains(
                _UIHostingMenuSelectorCatalog.RuntimeStrings.contextMenuBridgeClassFragment
            )
        } as? NSObject
    }

    private func findAnyContextMenuBridge() -> NSObject? {
        guard !isLookupForcedToFail else { return nil }
        if let bridge = findContextMenuBridge(from: hostingController.view as Any) {
            return bridge
        }
        if let bridge = findContextMenuBridge(from: hostingController as Any) {
            return bridge
        }
        if let bridge = bridgeBySelector(from: hostingController.view) {
            return bridge
        }
        if let bridge = findContextMenuBridgeByIvar(in: hostingController.view as AnyObject) {
            return bridge
        }
        return findContextMenuBridgeInViewTree(start: hostingController.view)
    }

    private func bridgeBySelector(from rootView: UIView) -> NSObject? {
        let selector = _UIHostingMenuSelectorCatalog.BridgeAccessors.contextMenuBridge
        guard rootView.responds(to: selector),
              let method = class_getInstanceMethod(type(of: rootView), selector)
        else {
            return nil
        }

        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        let implementation = method_getImplementation(method)
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(rootView, selector) as? NSObject
    }

    private func findContextMenuInteraction(from root: Any) -> UIContextMenuInteraction? {
        guard !isLookupForcedToFail else { return nil }
        var visited = Set<ObjectIdentifier>()
        return firstObject(in: root, visited: &visited) { $0 is UIContextMenuInteraction } as? UIContextMenuInteraction
    }

    private func findContextMenuBridgeByIvar(in object: AnyObject) -> NSObject? {
        var currentClass: AnyClass? = object_getClass(object)
        while let cls = currentClass {
            var count: UInt32 = 0
            guard let ivars = class_copyIvarList(cls, &count) else {
                currentClass = class_getSuperclass(cls)
                continue
            }
            defer { free(ivars) }

            for index in 0..<Int(count) {
                let ivar = ivars[index]
                guard let cName = ivar_getName(ivar) else { continue }
                let name = String(cString: cName)
                if !name.localizedCaseInsensitiveContains(
                    _UIHostingMenuSelectorCatalog.RuntimeStrings.contextMenuBridgeIvarFragment
                ) {
                    continue
                }
                if let value = objectIvarValue(from: object, ivar: ivar) as? NSObject {
                    return value
                }
            }
            currentClass = class_getSuperclass(cls)
        }
        return nil
    }

    private func findContextMenuBridgeInViewTree(start rootView: UIView?) -> NSObject? {
        guard let rootView else { return nil }

        if let bridge = findContextMenuBridgeByIvar(in: rootView) {
            return bridge
        }
        for subview in rootView.subviews {
            if let bridge = findContextMenuBridgeInViewTree(start: subview) {
                return bridge
            }
        }
        return nil
    }

    private func findInteraction(in bridge: NSObject) -> UIContextMenuInteraction? {
        if let direct = findContextMenuInteraction(from: bridge) {
            return direct
        }

        var currentClass: AnyClass? = object_getClass(bridge)
        while let cls = currentClass {
            var count: UInt32 = 0
            guard let ivars = class_copyIvarList(cls, &count) else {
                currentClass = class_getSuperclass(cls)
                continue
            }
            defer { free(ivars) }

            for index in 0..<Int(count) {
                let ivar = ivars[index]
                guard let cName = ivar_getName(ivar) else { continue }
                let name = String(cString: cName)
                if !name.localizedCaseInsensitiveContains("interaction") {
                    continue
                }
                if let value = objectIvarValue(from: bridge, ivar: ivar) as? UIContextMenuInteraction {
                    return value
                }
            }
            currentClass = class_getSuperclass(cls)
        }
        return nil
    }

    private func findContextMenuInteraction(in rootView: UIView?) -> UIContextMenuInteraction? {
        guard !isLookupForcedToFail else { return nil }
        guard let rootView else { return nil }

        if let direct = rootView.interactions.first(where: { $0 is UIContextMenuInteraction }) as? UIContextMenuInteraction {
            return direct
        }

        for subview in rootView.subviews {
            if let match = findContextMenuInteraction(in: subview) {
                return match
            }
        }
        return nil
    }

    private func configuration(
        from interaction: UIContextMenuInteraction,
        at location: CGPoint
    ) -> UIContextMenuConfiguration? {
        wireContextMenuBridgeIfNeeded(for: interaction)
        let effectiveLocation = resolvedLocation(location, in: interaction.view ?? hostingController.view)
        let privateSelector = _UIHostingMenuSelectorCatalog.InteractionRuntime.delegateConfigurationForMenuAtLocation
        if interaction.responds(to: privateSelector),
           let method = class_getInstanceMethod(type(of: interaction), privateSelector) {
            typealias Function = @convention(c) (AnyObject, Selector, CGPoint) -> AnyObject?
            let implementation = method_getImplementation(method)
            let function = unsafeBitCast(implementation, to: Function.self)
            if let configuration = function(interaction, privateSelector, effectiveLocation) as? UIContextMenuConfiguration {
                return configuration
            }
        }

        guard let delegate = interaction.delegate as AnyObject? else { return nil }
        return configuration(from: delegate, interaction: interaction, at: effectiveLocation)
    }

    private func configuration(
        from delegate: AnyObject,
        interaction: UIContextMenuInteraction,
        at location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let selector = _UIHostingMenuSelectorCatalog.ContextMenuCallbacks.configurationForMenuAtLocation
        return configuration(from: delegate, selector: selector) { object, sel in
            typealias Function = @convention(c) (AnyObject, Selector, UIContextMenuInteraction, CGPoint) -> AnyObject?
            guard let method = class_getInstanceMethod(type(of: object), sel) else { return nil }
            let implementation = method_getImplementation(method)
            let function = unsafeBitCast(implementation, to: Function.self)
            return function(object, sel, interaction, location)
        }
    }

    private func configuration(
        from bridge: NSObject,
        interaction: UIContextMenuInteraction,
        at location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let effectiveLocation = resolvedLocation(location, in: interaction.view ?? hostingController.view)
        let selector = _UIHostingMenuSelectorCatalog.ContextMenuCallbacks.configurationForMenuAtLocation
        return configuration(from: bridge, selector: selector) { object, sel in
            typealias Function = @convention(c) (AnyObject, Selector, UIContextMenuInteraction, CGPoint) -> AnyObject?
            guard let method = class_getInstanceMethod(type(of: object), sel) else { return nil }
            let implementation = method_getImplementation(method)
            let function = unsafeBitCast(implementation, to: Function.self)
            return function(object, sel, interaction, effectiveLocation)
        }
    }

    private func configuration(
        from object: AnyObject,
        selector: Selector,
        invocation: (AnyObject, Selector) -> AnyObject?
    ) -> UIContextMenuConfiguration? {
        guard object.responds(to: selector) else { return nil }
        return invocation(object, selector) as? UIContextMenuConfiguration
    }

    private func configurationBySearchingLocation(
        in interaction: UIContextMenuInteraction
    ) -> UIContextMenuConfiguration? {
        guard let view = interaction.view else { return nil }
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let insetX = min(2, bounds.width * 0.1)
        let insetY = min(2, bounds.height * 0.1)
        let candidates = [
            CGPoint(x: bounds.midX, y: bounds.midY),
            CGPoint(x: bounds.minX + insetX, y: bounds.minY + insetY),
            CGPoint(x: bounds.maxX - insetX, y: bounds.minY + insetY),
            CGPoint(x: bounds.minX + insetX, y: bounds.maxY - insetY),
            CGPoint(x: bounds.maxX - insetX, y: bounds.maxY - insetY)
        ]

        for point in candidates {
            if let configuration = configuration(from: interaction, at: point) {
                return configuration
            }
        }
        return nil
    }

    private func wireContextMenuBridgeIfNeeded(for interaction: UIContextMenuInteraction) {
        guard let delegate = interaction.delegate as AnyObject?,
              NSStringFromClass(type(of: delegate)).contains(
                  _UIHostingMenuSelectorCatalog.RuntimeStrings.contextMenuBridgeClassFragment
              ),
              let bridge = delegate as? NSObject
        else {
            return
        }

        wireContextMenuBridgeIfNeeded(bridge: bridge, interaction: interaction)
    }

    private func wireContextMenuBridgeIfNeeded(
        bridge: NSObject,
        interaction: UIContextMenuInteraction
    ) {
        _ = setObjectReference(
            bridge,
            selector: _UIHostingMenuSelectorCatalog.BridgeWiring.setInteraction,
            ivarName: "interaction",
            value: interaction
        )
        if let hostView = hostingController.view {
            _ = setObjectReference(
                bridge,
                selector: _UIHostingMenuSelectorCatalog.BridgeWiring.setHost,
                ivarName: "host",
                value: hostView
            )
        }
    }

    private func interaction(
        for bridge: NSObject,
        preferredInteraction: UIContextMenuInteraction?
    ) -> UIContextMenuInteraction {
        if let preferredInteraction {
            wireContextMenuBridgeIfNeeded(bridge: bridge, interaction: preferredInteraction)
            return preferredInteraction
        }

        if let existingInteraction = findInteraction(in: bridge) {
            wireContextMenuBridgeIfNeeded(bridge: bridge, interaction: existingInteraction)
            return existingInteraction
        }

        ensureSyntheticInteractionMountedIfNeeded()
        wireContextMenuBridgeIfNeeded(bridge: bridge, interaction: fallbackInteraction)
        return fallbackInteraction
    }

    private func ensureSyntheticInteractionMountedIfNeeded() {
        guard let hostView = hostingController.view else { return }
        guard fallbackInteraction.view == nil else { return }
        guard !hostView.interactions.contains(where: { $0 === fallbackInteraction }) else { return }
        hostView.addInteraction(fallbackInteraction)
    }

    private func fallbackInteractionForConfiguration(
        preferredInteraction: UIContextMenuInteraction?
    ) -> UIContextMenuInteraction? {
        if let mountedInteraction = findContextMenuInteraction(in: hostingController.view) {
            return mountedInteraction
        }
        return preferredInteraction
    }

    private func bridgeAfterDeferredInstallationIfNeeded() -> NSObject? {
        if let bridge = findAnyContextMenuBridge() {
            return bridge
        }
        waitForBridgeInstallationIfNeeded()
        return findAnyContextMenuBridge()
    }

    private func interactionAfterDeferredInstallationIfNeeded() -> UIContextMenuInteraction? {
        if let interaction = findContextMenuInteraction(in: hostingController.view) {
            return interaction
        }
        waitForBridgeInstallationIfNeeded()
        return findContextMenuInteraction(in: hostingController.view)
    }

    private func waitForBridgeInstallationIfNeeded() {
        guard !isLookupForcedToFail else { return }

        for _ in 0..<3 {
            if findAnyContextMenuBridge() != nil || findContextMenuInteraction(in: hostingController.view) != nil {
                return
            }

            containerController.view.setNeedsLayout()
            hostingController.view.setNeedsLayout()
            containerController.view.layoutIfNeeded()
            hostingController.view.layoutIfNeeded()
            CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0.001, true)
        }
    }

    private func setObjectReference(
        _ object: NSObject,
        selector: Selector,
        ivarName: String,
        value: AnyObject
    ) -> Bool {
        if object.responds(to: selector),
           let method = class_getInstanceMethod(type(of: object), selector) {
            typealias Setter = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            let implementation = method_getImplementation(method)
            let setter = unsafeBitCast(implementation, to: Setter.self)
            setter(object, selector, value)
            return true
        }

        guard let ivar = ivar(named: ivarName, in: object) else {
            return false
        }

        if ivarName == "host" {
            return storeWeakObjectReference(object, ivar: ivar, value: value)
        }

        object_setIvarWithStrongDefault(object, ivar, value)
        return true
    }

    private func resolvedLocation(_ location: CGPoint, in view: UIView?) -> CGPoint {
        guard let bounds = view?.bounds, bounds.width > 0, bounds.height > 0 else {
            return location
        }
        guard (0...1).contains(location.x), (0...1).contains(location.y) else {
            return location
        }
        return CGPoint(x: bounds.width * location.x, y: bounds.height * location.y)
    }

    private var isLookupForcedToFail: Bool {
#if DEBUG
        _UIHostingMenuLiveTesting.forceContextMenuLookupFailure
#else
        false
#endif
    }

    private func firstObject(
        in value: Any,
        visited: inout Set<ObjectIdentifier>,
        where predicate: (AnyObject) -> Bool
    ) -> AnyObject? {
        if let object = value as AnyObject? {
            let objectID = ObjectIdentifier(object)
            if visited.insert(objectID).inserted {
                if predicate(object) {
                    return object
                }
            } else {
                return nil
            }
        }

        let mirror = Mirror(reflecting: value)
        for child in mirror.children {
            if let found = firstObject(in: child.value, visited: &visited, where: predicate) {
                return found
            }
        }

        var parent = mirror.superclassMirror
        while let parentMirror = parent {
            for child in parentMirror.children {
                if let found = firstObject(in: child.value, visited: &visited, where: predicate) {
                    return found
                }
            }
            parent = parentMirror.superclassMirror
        }
        return nil
    }

    private static func pickWindowScene() -> UIWindowScene? {
#if APP_EXTENSION
        return nil
#else
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let foreground = scenes.first(where: { $0.activationState == .foregroundActive }) {
            return foreground
        }
        if let inactive = scenes.first(where: { $0.activationState == .foregroundInactive }) {
            return inactive
        }
        return scenes.first
#endif
    }

    private func objectIvarValue(from object: AnyObject, ivar: Ivar) -> AnyObject? {
        guard let typeEncoding = ivar_getTypeEncoding(ivar) else {
            return nil
        }
        let encoding = String(cString: typeEncoding)
        guard encoding.hasPrefix("@") else {
            return nil
        }
        return object_getIvar(object, ivar) as AnyObject?
    }

    private func ivar(named name: String, in object: NSObject) -> Ivar? {
        var currentClass: AnyClass? = object_getClass(object)
        while let cls = currentClass {
            if let ivar = class_getInstanceVariable(cls, name) {
                return ivar
            }
            currentClass = class_getSuperclass(cls)
        }
        return nil
    }

    private func storeWeakObjectReference(
        _ object: NSObject,
        ivar: Ivar,
        value: AnyObject
    ) -> Bool {
        let offset = ivar_getOffset(ivar)
        let storage = UnsafeMutableRawPointer(Unmanaged.passUnretained(object).toOpaque())
            .advanced(by: offset)
            .assumingMemoryBound(to: Optional<AnyObject>.self)
        objc_storeWeak(AutoreleasingUnsafeMutablePointer(storage), value)
        return true
    }

#if DEBUG
    private func debugBridgeDiagnostics() {
        guard !isLookupForcedToFail else { return }
        guard let rootView = hostingController.view else { return }
        let rootClass = NSStringFromClass(type(of: rootView))
        let interactions = rootView.interactions.map { NSStringFromClass(type(of: $0)) }
        print("DEBUG UIHostingMenu: bridge resolution failed. root=\(rootClass), interactions=\(interactions)")
    }
#endif
}

private enum _UIHostingMenuRuntimeAvailability {
    private static let updateVisibleMenuSelector = _UIHostingMenuSelectorCatalog.InteractionRuntime.updateVisibleMenuWithBlock

    static let canCallUpdateVisibleMenu: Bool =
        class_getInstanceMethod(UIContextMenuInteraction.self, updateVisibleMenuSelector) != nil
}

@MainActor
private enum _UIHostingMenuLiveRuntime {
    static var didInstallHooks = false
    static var liveUpdatesSupported = false
    static var forceDisabled = false

    static func activateIfNeeded() {
        guard !didInstallHooks else { return }
        didInstallHooks = true

        guard _UIHostingMenuRuntimeAvailability.canCallUpdateVisibleMenu else {
#if DEBUG
            print("DEBUG UIHostingMenu: live updates disabled because updateVisibleMenuWithBlock is unavailable.")
#endif
            return
        }
        liveUpdatesSupported = true

        if !_UIButtonUIHostingMenuSwizzler.install() {
            liveUpdatesSupported = false
#if DEBUG
            print("DEBUG UIHostingMenu: live updates disabled because swizzle install failed.")
#endif
        }
    }

    static var isLiveUpdateEnabled: Bool {
        liveUpdatesSupported && !forceDisabled
    }

    static func associateOwnerToken(_ owner: any _UIHostingMenuLiveMenuOwner, with menu: UIMenu) {
        let token = _UIHostingMenuOwnerToken(owner: owner)
        objc_setAssociatedObject(
            menu,
            &_UIHostingMenuAssociatedKeys.ownerTokenKey,
            token,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    static func ownerToken(from menu: UIMenu?) -> _UIHostingMenuOwnerToken? {
        guard let menu else { return nil }
        return objc_getAssociatedObject(menu, &_UIHostingMenuAssociatedKeys.ownerTokenKey) as? _UIHostingMenuOwnerToken
    }

    static func handleMenuAssignment(on button: UIButton, menu: UIMenu?) {
        guard let owner = ownerToken(from: menu)?.owner else {
            detachCoordinator(from: button)
            return
        }
        guard isLiveUpdateEnabled else { return }

        let liveCoordinator: _UIHostingMenuLiveCoordinator
        if let existing = coordinator(for: button) {
            liveCoordinator = existing
        } else {
            liveCoordinator = _UIHostingMenuLiveCoordinator()
            objc_setAssociatedObject(
                button,
                &_UIHostingMenuAssociatedKeys.liveCoordinatorKey,
                liveCoordinator,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        liveCoordinator.bind(owner: owner, button: button)
    }

    static func detachCoordinator(from button: UIButton) {
        guard let coordinator = coordinator(for: button) else { return }
        coordinator.unbind()
        objc_setAssociatedObject(
            button,
            &_UIHostingMenuAssociatedKeys.liveCoordinatorKey,
            nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    static func coordinator(for button: UIButton) -> _UIHostingMenuLiveCoordinator? {
        objc_getAssociatedObject(button, &_UIHostingMenuAssociatedKeys.liveCoordinatorKey) as? _UIHostingMenuLiveCoordinator
    }

    static func configuration(
        for button: UIButton,
        interaction: UIContextMenuInteraction,
        location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard isLiveUpdateEnabled else { return nil }
        guard let coordinator = coordinator(for: button) else { return nil }
        return coordinator.configuration(interaction: interaction, location: location)
    }

    static func willDisplay(
        for button: UIButton,
        interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration
    ) {
        guard let coordinator = coordinator(for: button) else { return }
        coordinator.menuWillDisplay(interaction: interaction, configuration: configuration)
    }

    static func willEnd(
        for button: UIButton,
        interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration
    ) {
        guard let coordinator = coordinator(for: button) else { return }
        coordinator.menuWillEnd(interaction: interaction, configuration: configuration)
    }

    static func isCoordinatorAttached(to button: UIButton) -> Bool {
        coordinator(for: button) != nil
    }
}

private enum _UIButtonUIHostingMenuSwizzler {
    static func install() -> Bool {
        let setMenuOK = swizzle(
            UIButton.self,
            original: _UIHostingMenuSelectorCatalog.ContextMenuCallbacks.setMenu,
            swizzled: #selector(UIButton._uihm_setMenu(_:))
        )
        let configOK = swizzle(
            UIButton.self,
            original: _UIHostingMenuSelectorCatalog.ContextMenuCallbacks.configurationForMenuAtLocation,
            swizzled: #selector(UIButton._uihm_contextMenuInteraction(_:configurationForMenuAtLocation:))
        )
        let willDisplayOK = swizzle(
            UIButton.self,
            original: _UIHostingMenuSelectorCatalog.ContextMenuCallbacks.previewForHighlightingMenuWithConfiguration,
            swizzled: #selector(UIButton._uihm_contextMenuInteraction(_:previewForHighlightingMenuWithConfiguration:))
        )
        let willEndOK = swizzle(
            UIButton.self,
            original: _UIHostingMenuSelectorCatalog.ContextMenuCallbacks.previewForDismissingMenuWithConfiguration,
            swizzled: #selector(UIButton._uihm_contextMenuInteraction(_:previewForDismissingMenuWithConfiguration:))
        )
        return setMenuOK && configOK && willDisplayOK && willEndOK
    }

    private static func swizzle(
        _ cls: AnyClass,
        original: Selector,
        swizzled: Selector
    ) -> Bool {
        guard let originalMethod = class_getInstanceMethod(cls, original),
              let swizzledMethod = class_getInstanceMethod(cls, swizzled)
        else {
            return false
        }

        let didAddMethod = class_addMethod(
            cls,
            original,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )
        if didAddMethod {
            class_replaceMethod(
                cls,
                swizzled,
                method_getImplementation(originalMethod),
                method_getTypeEncoding(originalMethod)
            )
        } else {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
        return true
    }
}

private extension UIButton {
    @objc func _uihm_setMenu(_ menu: UIMenu?) {
        _uihm_setMenu(menu)
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated {
            _UIHostingMenuLiveRuntime.handleMenuAssignment(on: self, menu: menu)
        }
    }

    @objc func _uihm_contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard Thread.isMainThread else {
            return _uihm_contextMenuInteraction(interaction, configurationForMenuAtLocation: location)
        }
        if let configuration = MainActor.assumeIsolated({
            _UIHostingMenuLiveRuntime.configuration(for: self, interaction: interaction, location: location)
        }) {
            return configuration
        }
        return _uihm_contextMenuInteraction(interaction, configurationForMenuAtLocation: location)
    }

    @objc func _uihm_contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                _UIHostingMenuLiveRuntime.willDisplay(for: self, interaction: interaction, configuration: configuration)
            }
        }
        return _uihm_contextMenuInteraction(interaction, previewForHighlightingMenuWithConfiguration: configuration)
    }

    @objc func _uihm_contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
    ) -> UITargetedPreview? {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                _UIHostingMenuLiveRuntime.willEnd(for: self, interaction: interaction, configuration: configuration)
            }
        }
        return _uihm_contextMenuInteraction(interaction, previewForDismissingMenuWithConfiguration: configuration)
    }
}

@MainActor
private final class _UIHostingMenuLiveCoordinator: NSObject {
    weak var owner: (any _UIHostingMenuLiveMenuOwner)?
    weak var button: UIButton?

    private var bridgeHost: _MenuHost?
    private weak var visibleInteraction: UIContextMenuInteraction?
    private weak var visibleConfiguration: UIContextMenuConfiguration?
    private var normalizedLocation = CGPoint(x: 0.5, y: 0.5)
    private var liveUpdatesEnabled = true

    func bind(owner: any _UIHostingMenuLiveMenuOwner, button: UIButton) {
        self.owner = owner
        self.button = button
        self.liveUpdatesEnabled = _UIHostingMenuLiveRuntime.isLiveUpdateEnabled
    }

    func unbind() {
        visibleInteraction = nil
        visibleConfiguration = nil
        bridgeHost?.detachWindow()
        bridgeHost = nil
        owner = nil
        button = nil
    }

    func configuration(
        interaction: UIContextMenuInteraction,
        location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard liveUpdatesEnabled,
              let owner
        else {
            return nil
        }

        normalizedLocation = normalize(location: location, in: interaction.view)

        do {
            let host = ensureBridgeHost(using: owner)
            host.mountIfNeeded()
            let bridgeConfiguration = try host.makeConfiguration(
                at: location,
                preferredInteraction: interaction
            )
            return wrappedConfiguration(from: bridgeConfiguration)
        } catch {
#if DEBUG
            print("DEBUG UIHostingMenu: bridge configuration failed (\(error.localizedDescription)). Falling back to static configuration.")
#endif
            guard let fallbackMenu = try? owner._uiHostingMenuBuildMenuForLiveUpdate(at: normalizedLocation) else {
                liveUpdatesEnabled = false
                return nil
            }
            let decorated = decorate(menu: fallbackMenu)
            return UIContextMenuConfiguration(
                identifier: NSUUID(),
                previewProvider: nil
            ) { _ in
                decorated
            }
        }
    }

    func menuWillDisplay(
        interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration
    ) {
        visibleInteraction = interaction
        visibleConfiguration = configuration

        guard liveUpdatesEnabled,
              let owner
        else {
            return
        }
        let host = ensureBridgeHost(using: owner)
        host.mountIfNeeded()
        host.notifyBridgeWillDisplay(interaction: interaction, configuration: configuration)
    }

    func menuWillEnd(
        interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration
    ) {
        guard liveUpdatesEnabled,
              let host = bridgeHost
        else {
            visibleInteraction = nil
            visibleConfiguration = nil
            return
        }
        host.notifyBridgeWillEnd(interaction: interaction, configuration: configuration)
        visibleInteraction = nil
        visibleConfiguration = nil
    }

    private func ensureBridgeHost(using owner: any _UIHostingMenuLiveMenuOwner) -> _MenuHost {
        if let bridgeHost {
            bridgeHost.updateRootView(owner._uiHostingMenuProbeRootView())
            return bridgeHost
        }
        let host = _MenuHost(rootView: owner._uiHostingMenuProbeRootView())
        bridgeHost = host
        return host
    }

    private func wrappedConfiguration(from base: UIContextMenuConfiguration) -> UIContextMenuConfiguration {
        guard let actionProvider = _UIHostingMenuIntrospection.actionProvider(from: base) else {
            return base
        }

        let identifier: NSCopying
        if let bridgedIdentifier = _UIHostingMenuIntrospection.configurationIdentifier(from: base) as? NSCopying {
            identifier = bridgedIdentifier
        } else {
            identifier = NSUUID()
        }
        return UIContextMenuConfiguration(identifier: identifier, previewProvider: nil) { [weak self] suggested in
            guard let menu = actionProvider(suggested) else { return nil }
            let normalized = _UIHostingMenuBridge.normalizeInlineSectionsIfNeeded(menu)
            guard let self else { return normalized }
            return self.decorate(menu: normalized)
        }
    }

    private func decorate(menu: UIMenu) -> UIMenu {
        let children = menu.children.map { decorate(element: $0) }
        return UIMenu(
            title: menu.title,
            subtitle: menu.subtitle,
            image: menu.image,
            identifier: menu.identifier,
            options: menu.options,
            preferredElementSize: menu.preferredElementSize,
            children: children
        )
    }

    private func decorate(element: UIMenuElement) -> UIMenuElement {
        if let submenu = element as? UIMenu {
            return decorate(menu: submenu)
        }
        if let action = element as? UIAction {
            return wrap(action: action)
        }
        return element
    }

    private func wrap(action: UIAction) -> UIAction {
        if let wrapped = objc_getAssociatedObject(action, &_UIHostingMenuAssociatedKeys.wrappedActionKey) as? UIAction {
            return wrapped
        }
        guard let originalHandler = _UIHostingMenuIntrospection.actionHandler(from: action) else {
            return action
        }

        let wrappedAction = UIAction(
            title: action.title,
            image: action.image,
            identifier: action.identifier,
            discoverabilityTitle: action.discoverabilityTitle,
            attributes: action.attributes,
            state: action.state
        ) { [weak self] invokedAction in
            originalHandler(invokedAction)
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.refreshVisibleMenuIfNeeded()
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.refreshVisibleMenuIfNeeded()
                }
            }
        }
        objc_setAssociatedObject(
            action,
            &_UIHostingMenuAssociatedKeys.wrappedActionKey,
            wrappedAction,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return wrappedAction
    }

    private func refreshVisibleMenuIfNeeded() {
        guard liveUpdatesEnabled,
              _UIHostingMenuRuntimeAvailability.canCallUpdateVisibleMenu,
              let interaction = visibleInteraction
        else {
            return
        }
        guard _UIHostingMenuIntrospection.hasVisibleMenu(interaction: interaction) else {
            visibleInteraction = nil
            visibleConfiguration = nil
            return
        }

        let refreshed = _UIHostingMenuIntrospection.updateVisibleMenu(interaction: interaction) { [weak self] current in
            guard let self else { return current }
            if let configuration = self.visibleConfiguration,
               let provider = _UIHostingMenuIntrospection.actionProvider(from: configuration),
               let rebuilt = provider(current.children) {
                let normalized = _UIHostingMenuBridge.normalizeInlineSectionsIfNeeded(rebuilt)
                // `visibleConfiguration` is already wrapped/decorated in the live-update path.
                // Re-decorating here would stack wrapped handlers on every refresh.
                return normalized
            }

            guard let owner = self.owner,
                  let rebuilt = try? owner._uiHostingMenuBuildMenuForLiveUpdate(at: self.normalizedLocation)
            else {
                return current
            }
            return self.decorate(menu: rebuilt)
        }

        if !refreshed {
            liveUpdatesEnabled = false
#if DEBUG
            print("DEBUG UIHostingMenu: updateVisibleMenuWithBlock unavailable. Disabling live updates.")
#endif
        }
    }

    private func normalize(location: CGPoint, in view: UIView?) -> CGPoint {
        guard let bounds = view?.bounds, bounds.width > 0, bounds.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let x = max(0, min(1, location.x / bounds.width))
        let y = max(0, min(1, location.y / bounds.height))
        return CGPoint(x: x, y: y)
    }
}

private enum _UIHostingMenuIntrospection {
    static func hasVisibleMenu(interaction: UIContextMenuInteraction) -> Bool {
        let selector = _UIHostingMenuSelectorCatalog.InteractionRuntime.hasVisibleMenu
        guard interaction.responds(to: selector),
              let method = class_getInstanceMethod(type(of: interaction), selector)
        else {
            return true
        }

        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = method_getImplementation(method)
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(interaction, selector)
    }

    static func actionProvider(
        from configuration: UIContextMenuConfiguration
    ) -> (([UIMenuElement]) -> UIMenu?)? {
        let selector = _UIHostingMenuSelectorCatalog.BridgeAccessors.actionProvider
        guard configuration.responds(to: selector),
              let method = class_getInstanceMethod(type(of: configuration), selector)
        else {
            return nil
        }

        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        typealias Provider = @convention(block) ([UIMenuElement]) -> UIMenu?

        let implementation = method_getImplementation(method)
        let getter = unsafeBitCast(implementation, to: Getter.self)
        guard let rawBlock = getter(configuration, selector) else {
            return nil
        }
        let provider = unsafeBitCast(rawBlock, to: Provider.self)
        return { suggested in provider(suggested) }
    }

    static func actionHandler(from action: UIAction) -> ((UIAction) -> Void)? {
        let selector = _UIHostingMenuSelectorCatalog.BridgeAccessors.handler
        guard action.responds(to: selector),
              let method = class_getInstanceMethod(type(of: action), selector)
        else {
            return nil
        }

        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        typealias Handler = @convention(block) (UIAction) -> Void

        let implementation = method_getImplementation(method)
        let getter = unsafeBitCast(implementation, to: Getter.self)
        guard let rawBlock = getter(action, selector) else { return nil }
        let handler = unsafeBitCast(rawBlock, to: Handler.self)
        return { event in handler(event) }
    }

    static func configurationIdentifier(from configuration: UIContextMenuConfiguration) -> AnyObject? {
        let selector = _UIHostingMenuSelectorCatalog.BridgeAccessors.identifier
        guard configuration.responds(to: selector),
              let method = class_getInstanceMethod(type(of: configuration), selector)
        else {
            return nil
        }
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        let implementation = method_getImplementation(method)
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(configuration, selector)
    }

    static func updateVisibleMenu(
        interaction: UIContextMenuInteraction,
        block: @escaping (UIMenu) -> UIMenu
    ) -> Bool {
        let selector = _UIHostingMenuSelectorCatalog.InteractionRuntime.updateVisibleMenuWithBlock
        guard interaction.responds(to: selector),
              let method = class_getInstanceMethod(type(of: interaction), selector)
        else {
            return false
        }
        typealias Update = @convention(c) (AnyObject, Selector, @convention(block) (UIMenu) -> UIMenu) -> Void
        let implementation = method_getImplementation(method)
        let update = unsafeBitCast(implementation, to: Update.self)
        update(interaction, selector, block)
        return true
    }
}

#if DEBUG
@MainActor
enum _UIHostingMenuLiveTesting {
    static var forceContextMenuLookupFailure = false

    static func isCoordinatorAttached(to button: UIButton) -> Bool {
        _UIHostingMenuLiveRuntime.isCoordinatorAttached(to: button)
    }

    static var isLiveUpdateActive: Bool {
        _UIHostingMenuLiveRuntime.isLiveUpdateEnabled
    }

    static func setForceDisableLiveUpdates(_ disabled: Bool) {
        _UIHostingMenuLiveRuntime.forceDisabled = disabled
    }

    static func setForceContextMenuLookupFailure(_ forced: Bool) {
        forceContextMenuLookupFailure = forced
    }

    static func makeConfiguration<Content: View>(
        from menu: UIHostingMenu<Content>,
        at location: CGPoint = CGPoint(x: 0.5, y: 0.5),
        preferredInteraction: UIContextMenuInteraction? = nil
    ) throws -> UIContextMenuConfiguration {
        let host = _MenuHost(rootView: menu._uiHostingMenuProbeRootView())
        host.mountIfNeeded()
        defer { host.detachWindow() }
        return try host.makeConfiguration(at: location, preferredInteraction: preferredInteraction)
    }

    static func menuTitles(from configuration: UIContextMenuConfiguration) -> [String] {
        guard let actionProvider = _UIHostingMenuIntrospection.actionProvider(from: configuration),
              let menu = actionProvider([])
        else {
            return []
        }

        return menu.children.compactMap { element in
            if let action = element as? UIAction {
                return action.title
            }
            if let submenu = element as? UIMenu {
                return submenu.title
            }
            return nil
        }
    }
}
#endif
