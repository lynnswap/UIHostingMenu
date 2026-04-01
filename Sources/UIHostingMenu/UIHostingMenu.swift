import Foundation
import ObjectiveC.runtime
import SwiftUI
import UIKit

public enum UIHostingMenuError: Swift.Error, LocalizedError, Equatable {
    case contextMenuBridgeNotFound
    case configurationMethodUnavailable
    case configurationBuildFailed
    case actionProviderMissing
    case menuBuildFailed
    case menuNotPrepared

    public var errorDescription: String? {
        switch self {
        case .contextMenuBridgeNotFound:
            return _UIHostingMenuSelectorCatalog.RuntimeStrings.contextMenuBridgeErrorDescription
        case .configurationMethodUnavailable:
            return "contextMenuInteraction:configurationForMenuAtLocation:completion: is unavailable."
        case .configurationBuildFailed:
            return "Failed to create UIContextMenuConfiguration."
        case .actionProviderMissing:
            return "UIContextMenuConfiguration.actionProvider is missing."
        case .menuBuildFailed:
            return "Failed to build UIMenu from actionProvider."
        case .menuNotPrepared:
            return "Menu is not prepared. Use install(on:) for UIButton, or call prepare(in:at:) first."
        }
    }
}

@MainActor
private protocol _UIHostingMenuLiveMenuOwner: AnyObject {
    func _uiHostingMenuProbeRootView() -> AnyView
    func _uiHostingMenuCachedMenu(for location: CGPoint) -> UIMenu?
    func _uiHostingMenuStorePreparedMenu(_ menu: UIMenu, location: CGPoint)
    func _uiHostingMenuPrepareMenu(in sourceView: UIView) async -> UIMenu?
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
    private var stateVersion: UInt64 = 0
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

    public func install(on button: UIButton) throws {
        _UIHostingMenuLiveRuntime.activateIfNeeded()
        guard _UIHostingMenuLiveRuntime.isButtonInstallAvailable else {
            throw UIHostingMenuError.configurationMethodUnavailable
        }

        let placeholder = _UIHostingMenuLiveRuntime.makePlaceholderMenu(for: self, on: button)
        button.menu = placeholder

        Task { @MainActor [weak self, weak button] in
            guard let self, let button else { return }
            guard let currentOwner = _UIHostingMenuLiveRuntime.ownerToken(from: button.menu)?.owner,
                  currentOwner as AnyObject === self
            else {
                return
            }

            guard let preparedMenu = try? await self.prepare(in: button) else {
                return
            }
            guard let latestOwner = _UIHostingMenuLiveRuntime.ownerToken(from: button.menu)?.owner,
                  latestOwner as AnyObject === self
            else {
                return
            }
            guard self.cachedMenu === preparedMenu, !self.needsUpdate else {
                return
            }
            button.menu = preparedMenu
        }
    }

    public func prepare(
        in sourceView: UIView,
        at location: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) async throws -> UIMenu {
        while true {
            if !needsUpdate,
               let cachedMenu,
               cachedLocation == location
            {
                return cachedMenu
            }

            let version = stateVersion
            let built = try await _UIHostingMenuBridge.prepareMenu(
                rootView: rootView,
                in: sourceView,
                at: location
            )
            guard version == stateVersion else {
                continue
            }
            _uiHostingMenuStorePreparedMenu(built, location: location)
            return built
        }
    }

    @available(
        *,
        deprecated,
        message: "Use install(on:) for UIButton, or call prepare(in:at:) before requesting a synchronous menu."
    )
    public func menu(at location: CGPoint = CGPoint(x: 0.5, y: 0.5)) throws -> UIMenu {
        guard !needsUpdate,
              let cachedMenu,
              cachedLocation == location
        else {
            throw UIHostingMenuError.menuNotPrepared
        }
        return cachedMenu
    }

    public func updateRootView(_ rootView: Content) {
        self.rootView = rootView
    }

    public func setNeedsUpdate() {
        stateVersion &+= 1
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
    fileprivate func _uiHostingMenuProbeRootView() -> AnyView {
        _UIHostingMenuBridge.makeProbeRootView(rootView: rootView)
    }

    fileprivate func _uiHostingMenuCachedMenu(for location: CGPoint) -> UIMenu? {
        guard !needsUpdate,
              let cachedMenu,
              cachedLocation == location
        else {
            return nil
        }
        return cachedMenu
    }

    fileprivate func _uiHostingMenuStorePreparedMenu(_ menu: UIMenu, location: CGPoint) {
        _UIHostingMenuLiveRuntime.activateIfNeeded()
        _UIHostingMenuLiveRuntime.associateOwnerToken(self, with: menu)
        cachedMenu = menu
        cachedLocation = location
        needsUpdate = false
    }

    fileprivate func _uiHostingMenuPrepareMenu(in sourceView: UIView) async -> UIMenu? {
        try? await prepare(in: sourceView)
    }
}

@MainActor
private enum _UIHostingMenuBridge {
    static func makeProbeRootView<Content: View>(rootView: Content) -> AnyView {
        AnyView(_ContextMenuProbeView(menuItems: rootView))
    }

    static func prepareMenu<Content: View>(
        rootView: Content,
        in sourceView: UIView,
        at location: CGPoint
    ) async throws -> UIMenu {
        let host = _MenuHost(rootView: makeProbeRootView(rootView: rootView))
        defer { host.detach() }

        let configuration = try await host.makeConfiguration(
            in: sourceView,
            at: location,
            preferredInteraction: nil
        )
        return try materializeMenu(from: configuration)
    }

    static func materializeMenu(from configuration: UIContextMenuConfiguration) throws -> UIMenu {
        guard let actionProvider = actionProvider(from: configuration) else {
            throw UIHostingMenuError.actionProviderMissing
        }
        guard let menu = actionProvider([]) else {
            throw UIHostingMenuError.menuBuildFailed
        }
        return normalizeInlineSectionsIfNeeded(menu)
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
    private let fallbackDelegate = _FallbackContextMenuDelegate()
    private lazy var fallbackInteraction = UIContextMenuInteraction(delegate: fallbackDelegate)
    private var didSetupContainer = false
    private var fallbackWindow: UIWindow?

    init(rootView: AnyView) {
        hostingController = UIHostingController(rootView: rootView)
        super.init()
    }

    func updateRootView(_ rootView: AnyView) {
        hostingController.rootView = rootView
        hostingController.view.setNeedsLayout()
        hostingController.view.layoutIfNeeded()
    }

    func mountIfNeeded(
        in sourceView: UIView,
        preferredInteraction: UIContextMenuInteraction?
    ) throws {
        setupContainerIfNeeded()

        let anchorView = preferredInteraction?.view ?? sourceView
        let parentController =
            nearestViewController(from: anchorView)
            ?? nearestViewController(from: sourceView)
            ?? sourceView.window?.rootViewController

        guard let parentController,
              let parentView = parentController.view
        else {
            mountInFallbackWindow()
            return
        }

        if containerController.parent === parentController,
           containerController.view.superview === parentView
        {
            return
        }

        if containerController.parent != nil || fallbackWindow != nil {
            detach()
        }

        parentController.addChild(containerController)
        parentView.addSubview(containerController.view)
        containerController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            containerController.view.leadingAnchor.constraint(equalTo: parentView.trailingAnchor, constant: 1),
            containerController.view.topAnchor.constraint(equalTo: parentView.bottomAnchor, constant: 1),
            containerController.view.widthAnchor.constraint(equalToConstant: 120),
            containerController.view.heightAnchor.constraint(equalToConstant: 120),
        ])
        containerController.didMove(toParent: parentController)

        parentView.setNeedsLayout()
        parentView.layoutIfNeeded()
        containerController.view.layoutIfNeeded()
        hostingController.view.layoutIfNeeded()
    }

    func detach() {
        if containerController.parent != nil {
            containerController.willMove(toParent: nil)
            containerController.view.removeFromSuperview()
            containerController.removeFromParent()
        }
        if let fallbackWindow {
            fallbackWindow.isHidden = true
            fallbackWindow.rootViewController = nil
            self.fallbackWindow = nil
        }
    }

    func makeConfiguration(
        in sourceView: UIView,
        at location: CGPoint,
        preferredInteraction: UIContextMenuInteraction?
    ) async throws -> UIContextMenuConfiguration {
        try mountIfNeeded(in: sourceView, preferredInteraction: preferredInteraction)

        var didTriggerPresentation = false
        for attempt in 0..<16 {
            if let configuration = immediateConfiguration(
                at: location,
                preferredInteraction: preferredInteraction
            ) {
                return configuration
            }

            if preferredInteraction == nil,
               !didTriggerPresentation
            {
                didTriggerPresentation = triggerProbePresentation(at: location)
            }

            if preferredInteraction == nil,
               let configuration = pendingProbeConfiguration()
            {
                return configuration
            }

            guard attempt < 15 else { break }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

#if DEBUG
        debugBridgeDiagnostics()
#endif
        throw UIHostingMenuError.configurationBuildFailed
    }

    func immediateConfiguration(
        at location: CGPoint,
        preferredInteraction: UIContextMenuInteraction?
    ) -> UIContextMenuConfiguration? {
        if let preferredInteraction,
           let bridge = findAnyContextMenuBridge()
        {
            wireContextMenuBridgeIfNeeded(bridge: bridge, interaction: preferredInteraction)
            let effectiveLocation = locationInBridgeHostSpace(
                location,
                sourceView: preferredInteraction.view,
                hostView: hostingController.view
            )
            if let configuration = configuration(
                from: bridge,
                interaction: preferredInteraction,
                at: effectiveLocation
            ) {
                return configuration
            }
        }

        if let probeInteraction = findContextMenuInteraction(in: hostingController.view) {
            if preferredInteraction == nil,
               let configuration = configuration(from: probeInteraction, at: location)
            {
                return configuration
            }

            if let bridge = findAnyContextMenuBridge() {
                let interaction = preferredInteraction ?? probeInteraction
                wireContextMenuBridgeIfNeeded(bridge: bridge, interaction: interaction)
                let effectiveLocation: CGPoint
                if let preferredInteraction {
                    effectiveLocation = locationInBridgeHostSpace(
                        location,
                        sourceView: preferredInteraction.view,
                        hostView: hostingController.view
                    )
                } else {
                    effectiveLocation = resolvedLocation(location, in: interaction.view ?? probeInteraction.view)
                }
                if let configuration = configuration(
                    from: bridge,
                    interaction: interaction,
                    at: effectiveLocation
                ) {
                    return configuration
                }
            }
        }

        if preferredInteraction == nil,
           let bridge = findAnyContextMenuBridge()
        {
            let interaction = findInteraction(in: bridge) ?? fallbackInteraction
            wireContextMenuBridgeIfNeeded(bridge: bridge, interaction: interaction)
            let effectiveLocation = resolvedLocation(location, in: interaction.view ?? hostingController.view)
            if let configuration = configuration(
                from: bridge,
                interaction: interaction,
                at: effectiveLocation
            ) {
                return configuration
            }
        }

        return nil
    }

    private func setupContainerIfNeeded() {
        guard !didSetupContainer else { return }
        didSetupContainer = true

        containerController.view.backgroundColor = .clear
        containerController.view.isOpaque = false
        containerController.view.alpha = 0.001
        containerController.view.isUserInteractionEnabled = false
        containerController.view.accessibilityElementsHidden = true

        hostingController.loadViewIfNeeded()
        hostingController.view.backgroundColor = .clear
        hostingController.view.isOpaque = false
        hostingController.view.alpha = 0.001
        hostingController.view.isUserInteractionEnabled = false

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
    }

    private func nearestViewController(from view: UIView?) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    private func mountInFallbackWindow() {
        let windowFrame = CGRect(x: -4096, y: -4096, width: 120, height: 120)
        if containerController.parent != nil {
            detach()
        }
        if let fallbackWindow {
            fallbackWindow.frame = windowFrame
            fallbackWindow.isHidden = false
            containerController.view.frame = fallbackWindow.bounds
            hostingController.view.frame = containerController.view.bounds
            containerController.view.layoutIfNeeded()
            hostingController.view.layoutIfNeeded()
            return
        }

        let window: UIWindow
        if let scene = Self.pickWindowScene() {
            window = UIWindow(windowScene: scene)
        } else {
            window = UIWindow(frame: windowFrame)
        }
        window.frame = windowFrame
        window.rootViewController = containerController
        window.backgroundColor = .clear
        window.alpha = 0.001
        window.isHidden = false
        containerController.view.frame = window.bounds
        hostingController.view.frame = containerController.view.bounds
        containerController.view.layoutIfNeeded()
        hostingController.view.layoutIfNeeded()
        fallbackWindow = window
    }

    private func triggerProbePresentation(at location: CGPoint) -> Bool {
        guard let interaction = findContextMenuInteraction(in: hostingController.view) else {
            return false
        }
        let selector = _UIHostingMenuSelectorCatalog.InteractionRuntime.presentMenuAtLocation
        guard interaction.responds(to: selector),
              let method = class_getInstanceMethod(type(of: interaction), selector)
        else {
            return false
        }

        typealias Presenter = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        let implementation = method_getImplementation(method)
        let presenter = unsafeBitCast(implementation, to: Presenter.self)
        presenter(interaction, selector, resolvedLocation(location, in: interaction.view))
        return true
    }

    private func pendingProbeConfiguration() -> UIContextMenuConfiguration? {
        guard let interaction = findContextMenuInteraction(in: hostingController.view) else {
            return nil
        }

        if let pending = objectValue(
            for: interaction,
            selector: _UIHostingMenuSelectorCatalog.InteractionRuntime.pendingConfiguration
        ) as? UIContextMenuConfiguration {
            return pending
        }

        if let configurations = objectValue(
            for: interaction,
            selector: _UIHostingMenuSelectorCatalog.InteractionRuntime.configurationsByIdentifier
        ) as? NSDictionary {
            for candidate in configurations.allValues {
                if let configuration = candidate as? UIContextMenuConfiguration {
                    return configuration
                }
            }
        }

        return nil
    }

    private func configuration(
        from interaction: UIContextMenuInteraction,
        at location: CGPoint
    ) -> UIContextMenuConfiguration? {
        wireContextMenuBridgeIfNeeded(for: interaction)
        let effectiveLocation = resolvedLocation(location, in: interaction.view)
        let privateSelector = _UIHostingMenuSelectorCatalog.InteractionRuntime.delegateConfigurationForMenuAtLocation
        if interaction.responds(to: privateSelector),
           let method = class_getInstanceMethod(type(of: interaction), privateSelector)
        {
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
        let selector = _UIHostingMenuSelectorCatalog.ContextMenuCallbacks.configurationForMenuAtLocation
        return configuration(from: bridge, selector: selector) { object, sel in
            typealias Function = @convention(c) (AnyObject, Selector, UIContextMenuInteraction, CGPoint) -> AnyObject?
            guard let method = class_getInstanceMethod(type(of: object), sel) else { return nil }
            let implementation = method_getImplementation(method)
            let function = unsafeBitCast(implementation, to: Function.self)
            return function(object, sel, interaction, location)
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

    private func findContextMenuBridge(from root: Any) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        return firstObject(in: root, visited: &visited) { object in
            NSStringFromClass(type(of: object)).contains(
                _UIHostingMenuSelectorCatalog.RuntimeStrings.contextMenuBridgeClassFragment
            )
        } as? NSObject
    }

    private func findAnyContextMenuBridge() -> NSObject? {
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

    private func objectValue(for object: AnyObject, selector: Selector) -> AnyObject? {
        guard object.responds(to: selector),
              let method = class_getInstanceMethod(type(of: object), selector)
        else {
            return nil
        }

        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        let implementation = method_getImplementation(method)
        let getter = unsafeBitCast(implementation, to: Getter.self)
        return getter(object, selector)
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

        _ = setObjectReference(
            bridge,
            selector: _UIHostingMenuSelectorCatalog.BridgeWiring.setHost,
            ivarName: "host",
            value: hostingController.view
        )
    }

    private func setObjectReference(
        _ object: NSObject,
        selector: Selector,
        ivarName: String,
        value: AnyObject
    ) -> Bool {
        if object.responds(to: selector),
           let method = class_getInstanceMethod(type(of: object), selector)
        {
            typealias Setter = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            let implementation = method_getImplementation(method)
            let setter = unsafeBitCast(implementation, to: Setter.self)
            setter(object, selector, value)
            return true
        }
        return false
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

    private func locationInBridgeHostSpace(
        _ location: CGPoint,
        sourceView: UIView?,
        hostView: UIView?
    ) -> CGPoint {
        let sourceLocation = resolvedLocation(location, in: sourceView)
        guard let sourceBounds = sourceView?.bounds,
              sourceBounds.width > 0,
              sourceBounds.height > 0,
              let hostBounds = hostView?.bounds,
              hostBounds.width > 0,
              hostBounds.height > 0
        else {
            return sourceLocation
        }

        return CGPoint(
            x: max(0, min(1, sourceLocation.x / sourceBounds.width)) * hostBounds.width,
            y: max(0, min(1, sourceLocation.y / sourceBounds.height)) * hostBounds.height
        )
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

#if DEBUG
    private func debugBridgeDiagnostics() {
        let rootClass = NSStringFromClass(type(of: hostingController.view))
        let interactions = hostingController.view.interactions.map { NSStringFromClass(type(of: $0)) }
        print("DEBUG UIHostingMenu: bridge resolution failed. root=\(rootClass), interactions=\(interactions)")
    }
#endif
}

private enum _UIHostingMenuRuntimeAvailability {
    static let updateVisibleMenuSelector = _UIHostingMenuSelectorCatalog.InteractionRuntime.updateVisibleMenuWithBlock

    static let canCallUpdateVisibleMenu: Bool =
        class_getInstanceMethod(UIContextMenuInteraction.self, updateVisibleMenuSelector) != nil
}

#if DEBUG
private enum _UIHostingMenuDebugState {
    nonisolated(unsafe) static var forcedVisibleMenu: UIMenu?
    nonisolated(unsafe) static var updateVisibleMenuCallCount = 0
}
#endif

@MainActor
private enum _UIHostingMenuLiveRuntime {
    static var didInstallHooks = false
    static var buttonInstallAvailable = false
    static var liveUpdatesSupported = false
    static var forceDisabled = false

    static func activateIfNeeded() {
        guard !didInstallHooks else { return }
        didInstallHooks = true

        buttonInstallAvailable = _UIButtonUIHostingMenuSwizzler.install()
        if !buttonInstallAvailable {
#if DEBUG
            print("DEBUG UIHostingMenu: button hook installation failed.")
#endif
            return
        }

        liveUpdatesSupported = _UIHostingMenuRuntimeAvailability.canCallUpdateVisibleMenu
        if !liveUpdatesSupported {
#if DEBUG
            print("DEBUG UIHostingMenu: live updates disabled because updateVisibleMenuWithBlock is unavailable.")
#endif
        }
    }

    static var isButtonInstallAvailable: Bool {
        buttonInstallAvailable
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

    static func makePlaceholderMenu(
        for owner: any _UIHostingMenuLiveMenuOwner,
        on button: UIButton
    ) -> UIMenu {
        let token = _UIHostingMenuOwnerToken(owner: owner)
        let deferred = UIDeferredMenuElement.uncached { [weak button, weak token] completion in
            Task { @MainActor in
                guard let button,
                      let owner = token?.owner
                else {
                    completion([])
                    return
                }

                if let cachedMenu = owner._uiHostingMenuCachedMenu(for: CGPoint(x: 0.5, y: 0.5)) {
                    completion(Array(cachedMenu.children))
                    return
                }

                guard let preparedMenu = await owner._uiHostingMenuPrepareMenu(in: button) else {
                    completion([])
                    return
                }

                completion(Array(preparedMenu.children))
            }
        }
        let placeholder = UIMenu(title: "", children: [deferred])
        objc_setAssociatedObject(
            placeholder,
            &_UIHostingMenuAssociatedKeys.ownerTokenKey,
            token,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return placeholder
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
        guard buttonInstallAvailable else { return }

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

    static func synchronousConfiguration(
        for button: UIButton,
        interaction: UIContextMenuInteraction,
        location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let coordinator = coordinator(for: button) else { return nil }
        return coordinator.synchronousConfiguration(interaction: interaction, location: location)
    }

    static func asyncConfiguration(
        for button: UIButton,
        interaction: UIContextMenuInteraction,
        location: CGPoint
    ) async -> UIContextMenuConfiguration? {
        guard let coordinator = coordinator(for: button) else { return nil }
        return await coordinator.asyncConfiguration(interaction: interaction, location: location)
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

@MainActor
private enum _UIButtonUIHostingMenuSwizzler {
    private static var asyncConfigurationOriginalIMP: IMP?

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
        let asyncConfigOK = installAsyncConfigurationHook()
        let willDisplayOK = swizzle(
            UIButton.self,
            original: _UIHostingMenuSelectorCatalog.ContextMenuCallbacks.willDisplayMenuForConfiguration,
            swizzled: #selector(UIButton._uihm_contextMenuInteraction(_:willDisplayMenuForConfiguration:animator:))
        )
        let willEndOK = swizzle(
            UIButton.self,
            original: _UIHostingMenuSelectorCatalog.ContextMenuCallbacks.willEndForConfiguration,
            swizzled: #selector(UIButton._uihm_contextMenuInteraction(_:willEndForConfiguration:animator:))
        )

        return setMenuOK && configOK && asyncConfigOK && willDisplayOK && willEndOK
    }

    static func callOriginalAsyncConfigurationIfNeeded(
        on button: UIButton,
        interaction: UIContextMenuInteraction,
        location: CGPoint,
        completion: @escaping @convention(block) (UIContextMenuConfiguration?) -> Void
    ) -> Bool {
        guard let asyncConfigurationOriginalIMP else { return false }

        typealias Function = @convention(c) (
            AnyObject,
            Selector,
            UIContextMenuInteraction,
            CGPoint,
            @escaping @convention(block) (UIContextMenuConfiguration?) -> Void
        ) -> Void
        let function = unsafeBitCast(asyncConfigurationOriginalIMP, to: Function.self)
        function(
            button,
            _UIHostingMenuSelectorCatalog.ContextMenuCallbacks.asyncConfigurationForMenuAtLocationCompletion,
            interaction,
            location,
            completion
        )
        return true
    }

    private static func installAsyncConfigurationHook() -> Bool {
        let original = _UIHostingMenuSelectorCatalog.ContextMenuCallbacks.asyncConfigurationForMenuAtLocationCompletion
        let swizzled = #selector(UIButton._uihm_contextMenuInteraction(_:configurationForMenuAtLocation:completion:))
        let cls: AnyClass = UIButton.self

        guard let swizzledMethod = class_getInstanceMethod(cls, swizzled) else {
            return false
        }

        if let originalMethod = class_getInstanceMethod(cls, original) {
            asyncConfigurationOriginalIMP = method_getImplementation(originalMethod)

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

        return class_addMethod(
            cls,
            original,
            method_getImplementation(swizzledMethod),
            method_getTypeEncoding(swizzledMethod)
        )
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
            _UIHostingMenuLiveRuntime.synchronousConfiguration(for: self, interaction: interaction, location: location)
        }) {
            return configuration
        }

        return _uihm_contextMenuInteraction(interaction, configurationForMenuAtLocation: location)
    }

    @objc func _uihm_contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint,
        completion: @escaping @convention(block) (UIContextMenuConfiguration?) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                completion(nil)
                return
            }

            if let configuration = await _UIHostingMenuLiveRuntime.asyncConfiguration(
                for: self,
                interaction: interaction,
                location: location
            ) {
                completion(configuration)
                return
            }

            if _UIButtonUIHostingMenuSwizzler.callOriginalAsyncConfigurationIfNeeded(
                on: self,
                interaction: interaction,
                location: location,
                completion: completion
            ) {
                return
            }

            completion(nil)
        }
    }

    @objc func _uihm_contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuForConfiguration configuration: UIContextMenuConfiguration,
        animator: AnyObject?
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                _UIHostingMenuLiveRuntime.willDisplay(
                    for: self,
                    interaction: interaction,
                    configuration: configuration
                )
            }
        }

        _uihm_contextMenuInteraction(
            interaction,
            willDisplayMenuForConfiguration: configuration,
            animator: animator
        )
    }

    @objc func _uihm_contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndForConfiguration configuration: UIContextMenuConfiguration,
        animator: AnyObject?
    ) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                _UIHostingMenuLiveRuntime.willEnd(
                    for: self,
                    interaction: interaction,
                    configuration: configuration
                )
            }
        }

        _uihm_contextMenuInteraction(
            interaction,
            willEndForConfiguration: configuration,
            animator: animator
        )
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

    func bind(owner: any _UIHostingMenuLiveMenuOwner, button: UIButton) {
        self.owner = owner
        self.button = button
    }

    func unbind() {
        visibleInteraction = nil
        visibleConfiguration = nil
        bridgeHost?.detach()
        bridgeHost = nil
        owner = nil
        button = nil
    }

    func asyncConfiguration(
        interaction: UIContextMenuInteraction,
        location: CGPoint
    ) async -> UIContextMenuConfiguration? {
        guard let owner,
              let sourceView = interaction.view ?? button
        else {
            return nil
        }

        normalizedLocation = normalize(location: location, in: interaction.view ?? sourceView)

        do {
            let host = ensureBridgeHost(using: owner)
            let configuration = try await host.makeConfiguration(
                in: sourceView,
                at: location,
                preferredInteraction: interaction
            )
            return wrappedConfiguration(from: configuration)
        } catch {
#if DEBUG
            print("DEBUG UIHostingMenu: async configuration failed (\(error.localizedDescription)). Falling back.")
#endif
            return cachedConfiguration(from: owner)
        }
    }

    func synchronousConfiguration(
        interaction: UIContextMenuInteraction,
        location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let owner,
              let sourceView = interaction.view ?? button
        else {
            return nil
        }

        normalizedLocation = normalize(location: location, in: interaction.view ?? sourceView)

        do {
            let host = ensureBridgeHost(using: owner)
            try host.mountIfNeeded(in: sourceView, preferredInteraction: interaction)
            if let configuration = host.immediateConfiguration(
                at: location,
                preferredInteraction: interaction
            ) {
                return wrappedConfiguration(from: configuration)
            }
        } catch {
#if DEBUG
            print("DEBUG UIHostingMenu: synchronous configuration failed (\(error.localizedDescription)).")
#endif
        }

        return cachedConfiguration(from: owner)
    }

    func menuWillDisplay(
        interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration
    ) {
        visibleInteraction = interaction
        visibleConfiguration = configuration
    }

    func menuWillEnd(
        interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration
    ) {
        if let host = bridgeHost {
            host.detach()
        }

        visibleInteraction = nil
        visibleConfiguration = nil
    }

#if DEBUG
    func setTestingVisibleMenu(
        interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration
    ) {
        visibleInteraction = interaction
        visibleConfiguration = configuration
    }

    func clearTestingVisibleMenu() {
        visibleInteraction = nil
        visibleConfiguration = nil
    }
#endif

    private func ensureBridgeHost(using owner: any _UIHostingMenuLiveMenuOwner) -> _MenuHost {
        if let bridgeHost {
            bridgeHost.updateRootView(owner._uiHostingMenuProbeRootView())
            return bridgeHost
        }

        let host = _MenuHost(rootView: owner._uiHostingMenuProbeRootView())
        bridgeHost = host
        return host
    }

    private func cachedConfiguration(
        from owner: any _UIHostingMenuLiveMenuOwner
    ) -> UIContextMenuConfiguration? {
        guard let cachedMenu = owner._uiHostingMenuCachedMenu(for: normalizedLocation) else {
            return nil
        }
        return staticConfiguration(from: cachedMenu)
    }

    private func staticConfiguration(from menu: UIMenu) -> UIContextMenuConfiguration {
        let decorated = decorate(menu: menu)
        return UIContextMenuConfiguration(identifier: NSUUID(), previewProvider: nil) { _ in
            decorated
        }
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
        guard _UIHostingMenuLiveRuntime.isLiveUpdateEnabled,
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

            if let owner = self.owner,
               let host = self.bridgeHost
            {
                host.updateRootView(owner._uiHostingMenuProbeRootView())
                if let refreshedConfiguration = host.immediateConfiguration(
                    at: self.normalizedLocation,
                    preferredInteraction: interaction
                ),
                   let provider = _UIHostingMenuIntrospection.actionProvider(from: refreshedConfiguration),
                   let rebuilt = provider(current.children)
                {
                    let normalized = _UIHostingMenuBridge.normalizeInlineSectionsIfNeeded(rebuilt)
                    return self.decorate(menu: normalized)
                }
            }

            if let configuration = self.visibleConfiguration,
               let provider = _UIHostingMenuIntrospection.actionProvider(from: configuration),
               let rebuilt = provider(current.children)
            {
                return rebuilt
            }

            if let owner = self.owner,
               let cachedMenu = owner._uiHostingMenuCachedMenu(for: self.normalizedLocation) {
                return self.decorate(menu: cachedMenu)
            }

            return current
        }

        if !refreshed {
#if DEBUG
            print("DEBUG UIHostingMenu: updateVisibleMenuWithBlock unavailable. Disabling live updates.")
#endif
        }
    }

    private func normalize(location: CGPoint, in view: UIView) -> CGPoint {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        let x = max(0, min(1, location.x / bounds.width))
        let y = max(0, min(1, location.y / bounds.height))
        return CGPoint(x: x, y: y)
    }
}

private enum _UIHostingMenuIntrospection {
    static func hasVisibleMenu(interaction: UIContextMenuInteraction) -> Bool {
#if DEBUG
        if _UIHostingMenuDebugState.forcedVisibleMenu != nil {
            return true
        }
#endif

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
#if DEBUG
        if let forcedVisibleMenu = _UIHostingMenuDebugState.forcedVisibleMenu {
            _UIHostingMenuDebugState.updateVisibleMenuCallCount += 1
            _UIHostingMenuDebugState.forcedVisibleMenu = block(forcedVisibleMenu)
            return true
        }
#endif

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
    static func isCoordinatorAttached(to button: UIButton) -> Bool {
        _UIHostingMenuLiveRuntime.isCoordinatorAttached(to: button)
    }

    static var isButtonInstallAvailable: Bool {
        _UIHostingMenuLiveRuntime.isButtonInstallAvailable
    }

    static var isLiveUpdateActive: Bool {
        _UIHostingMenuLiveRuntime.isLiveUpdateEnabled
    }

    static var asyncConfigurationSelector: Selector {
        _UIHostingMenuSelectorCatalog.ContextMenuCallbacks.asyncConfigurationForMenuAtLocationCompletion
    }

    static func setForceDisableLiveUpdates(_ disabled: Bool) {
        _UIHostingMenuLiveRuntime.forceDisabled = disabled
    }

    static func makeConfiguration(
        on button: UIButton,
        location: CGPoint = CGPoint(x: 8, y: 8)
    ) async -> UIContextMenuConfiguration? {
        guard let interaction = button.contextMenuInteraction else {
            return nil
        }
        return await _UIHostingMenuLiveRuntime.asyncConfiguration(
            for: button,
            interaction: interaction,
            location: location
        )
    }

    static func markMenuVisible(
        on button: UIButton,
        interaction: UIContextMenuInteraction,
        configuration: UIContextMenuConfiguration
    ) {
        _UIHostingMenuLiveRuntime.coordinator(for: button)?.setTestingVisibleMenu(
            interaction: interaction,
            configuration: configuration
        )
    }

    static func clearVisibleMenu(on button: UIButton) {
        _UIHostingMenuLiveRuntime.coordinator(for: button)?.clearTestingVisibleMenu()
    }

    static func detachButtonCoordinator(from button: UIButton) {
        _UIHostingMenuLiveRuntime.detachCoordinator(from: button)
    }

    static func resetVisibleMenuTracking() {
        _UIHostingMenuDebugState.forcedVisibleMenu = nil
        _UIHostingMenuDebugState.updateVisibleMenuCallCount = 0
    }

    static func setForcedVisibleMenu(_ menu: UIMenu?) {
        _UIHostingMenuDebugState.forcedVisibleMenu = menu
    }

    static var forcedVisibleMenu: UIMenu? {
        _UIHostingMenuDebugState.forcedVisibleMenu
    }

    static var updateVisibleMenuCallCount: Int {
        _UIHostingMenuDebugState.updateVisibleMenuCallCount
    }
}
#endif
