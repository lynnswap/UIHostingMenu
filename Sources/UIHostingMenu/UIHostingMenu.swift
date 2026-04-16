import Foundation

#if canImport(UIKit)
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
private enum _UIHostingMenuAssociatedKeys {
    static var wrappedActionKey: UInt8 = 0
}

/// iOS private API PoC.
/// - Notes:
///   - This mirrors NSHostingMenu's "rootView + cached result + update request" shape.
///   - Internally it drives a hidden `_UIHostingView` render cycle, then asks `SwiftUI.ContextMenuBridge`
///     to materialize a `UIContextMenuConfiguration`.
@MainActor
public final class UIHostingMenu<Content: View> {
    public typealias BuildError = UIHostingMenuError

    public var rootView: Content {
        didSet {
            invalidateHostForRootViewChange()
            setNeedsUpdate()
        }
    }

    public private(set) var cachedMenu: UIMenu?

    private var needsUpdate = true
    private var cachedLocation: CGPoint?
    private var preferredBuildLocation = CGPoint(x: 0.5, y: 0.5)
    private var buildGeneration = 0
    private var invalidationTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?
    private var menuHost: _MenuHost?
    private weak var cachedShellMenu: UIMenu?
    private var prewarmedMenu: UIMenu?
    private var lastConcreteMenu: UIMenu?
    private var prewarmedLocation: CGPoint?
    private var prewarmedGeneration = 0
#if DEBUG
    fileprivate var lastResolutionUsedWarmCache = false
#endif

    public init(rootView: Content) {
        self.rootView = rootView
    }

    public convenience init(@ViewBuilder menuItems: () -> Content) {
        self.init(rootView: menuItems())
    }

    deinit {
        invalidationTask?.cancel()
        prewarmTask?.cancel()
    }

    public func menu(at location: CGPoint = CGPoint(x: 0.5, y: 0.5)) throws -> UIMenu {
        preferredBuildLocation = location
        if !needsUpdate,
           let cachedShellMenu,
           cachedLocation == location
        {
            return cachedShellMenu
        }

        prewarmTask?.cancel()
        return try rebuildMenu(at: location)
    }

    public func updateRootView(_ rootView: Content) {
        self.rootView = rootView
    }

    public func setNeedsUpdate() {
        invalidationTask?.cancel()
        prewarmTask?.cancel()
        buildGeneration += 1
        needsUpdate = true
        cachedMenu = nil
        prewarmedMenu = nil
        prewarmedLocation = nil
        schedulePrewarm(for: buildGeneration, location: cachedLocation ?? preferredBuildLocation)
    }

    public func requestUpdate(after delay: TimeInterval = 0) {
        invalidationTask?.cancel()
        prewarmTask?.cancel()
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

    private func rebuildMenu(at location: CGPoint) throws -> UIMenu {
        _UIHostingMenuInteractionRuntime.activateIfNeeded()
        let host = ensureMenuHost()
        host.mountIfNeeded()

        let concreteMenu = try concreteMenu(at: location)

        let shell: UIMenu
        if let cachedShellMenu,
           cachedLocation == location,
           shellMetadataMatches(cachedShellMenu, concreteMenu: concreteMenu) {
            shell = cachedShellMenu
        } else {
            shell = makeShellMenu(from: concreteMenu, at: location)
        }

        cachedMenu = concreteMenu
        lastConcreteMenu = concreteMenu
        cachedShellMenu = shell
        cachedLocation = location
        return shell
    }

    private func ensureMenuHost() -> _MenuHost {
        let probeRootView = _UIHostingMenuBridge.makeProbeRootView(rootView: rootView)
        if let menuHost {
            menuHost.updateRootView(probeRootView)
            return menuHost
        }
        let menuHost = _MenuHost(rootView: probeRootView)
        self.menuHost = menuHost
        return menuHost
    }

    private func invalidateHostForRootViewChange() {
        menuHost?.detachWindow()
        menuHost = nil
        cachedMenu = nil
        cachedShellMenu = nil
        lastConcreteMenu = nil
    }

    private func schedulePrewarm(for generation: Int, location: CGPoint) {
        prewarmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.buildGeneration == generation else { return }

            let host = self.ensureMenuHost()
            host.mountIfNeeded()
            let built = try? _UIHostingMenuBridge.makeConcreteMenu(using: host, at: location)
            guard !Task.isCancelled,
                  self.buildGeneration == generation,
                  let built
            else {
                return
            }
            self.wireActionHandlers(in: built)
            self.storePrewarmedMenu(built, at: location, generation: generation)
        }
    }

    fileprivate var hasWarmCacheForTesting: Bool {
        prewarmedMenu != nil && !needsUpdate && prewarmedGeneration == buildGeneration
    }

    fileprivate func _uiHostingMenuProbeRootView() -> AnyView {
        _UIHostingMenuBridge.makeProbeRootView(rootView: rootView)
    }

#if DEBUG
    fileprivate var lastResolutionUsedWarmCacheForTesting: Bool {
        lastResolutionUsedWarmCache
    }
#endif

    private func makeShellMenu(from concreteMenu: UIMenu, at location: CGPoint) -> UIMenu {
        let deferred = UIDeferredMenuElement.uncached { [self] completion in
            let resolve = { @MainActor in
                let elements = (try? self.concreteMenu(at: location).children)
                    ?? self.lastConcreteMenu?.children
                    ?? []
                completion(elements)
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    resolve()
                }
            } else {
                Task { @MainActor in
                    resolve()
                }
            }
        }

        return UIMenu(
            title: concreteMenu.title,
            subtitle: concreteMenu.subtitle,
            image: concreteMenu.image,
            identifier: concreteMenu.identifier,
            options: concreteMenu.options,
            preferredElementSize: concreteMenu.preferredElementSize,
            children: [deferred]
        )
    }

    private func shellMetadataMatches(_ shell: UIMenu, concreteMenu: UIMenu) -> Bool {
        shell.title == concreteMenu.title
            && shell.subtitle == concreteMenu.subtitle
            && identifiersMatch(shell.identifier, concreteMenu.identifier)
            && shell.options == concreteMenu.options
            && shell.preferredElementSize == concreteMenu.preferredElementSize
            && imagesMatch(shell.image, concreteMenu.image)
    }

    private func identifiersMatch(_ lhs: UIMenu.Identifier, _ rhs: UIMenu.Identifier) -> Bool {
        lhs == rhs
            || (isDynamicIdentifier(lhs) && isDynamicIdentifier(rhs))
    }

    private func isDynamicIdentifier(_ identifier: UIMenu.Identifier) -> Bool {
        identifier.rawValue.hasPrefix("com.apple.menu.dynamic.")
    }

    private func imagesMatch(_ lhs: UIImage?, _ rhs: UIImage?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            lhs === rhs || lhs.isEqual(rhs)
        default:
            false
        }
    }

    private func concreteMenu(at location: CGPoint) throws -> UIMenu {
        if let prewarmedMenu,
           prewarmedLocation == location,
           prewarmedGeneration == buildGeneration,
           !needsUpdate {
#if DEBUG
            lastResolutionUsedWarmCache = true
#endif
            return prewarmedMenu
        }

#if DEBUG
        lastResolutionUsedWarmCache = false
#endif

        let host = ensureMenuHost()
        host.mountIfNeeded()
        let built = try _UIHostingMenuBridge.makeConcreteMenu(using: host, at: location)
        wireActionHandlers(in: built)
        storePrewarmedMenu(built, at: location, generation: buildGeneration)
        return built
    }

    private func storePrewarmedMenu(_ menu: UIMenu, at location: CGPoint, generation: Int) {
        prewarmedMenu = menu
        prewarmedLocation = location
        prewarmedGeneration = generation
        needsUpdate = false
    }

    private func wireActionHandlers(in menu: UIMenu) {
        for child in menu.children {
            if let submenu = child as? UIMenu {
                wireActionHandlers(in: submenu)
                continue
            }
            guard let action = child as? UIAction else { continue }
            wrap(action: action)
        }
    }

    private func wrap(action: UIAction) {
        guard objc_getAssociatedObject(action, &_UIHostingMenuAssociatedKeys.wrappedActionKey) == nil else {
            return
        }
        guard let originalHandler = _UIHostingMenuIntrospection.actionHandler(from: action) else {
            return
        }

        _UIHostingMenuIntrospection.setActionHandler(
            for: action
        ) { [weak self] invokedAction in
            originalHandler(invokedAction)
            self?.actionDidInvoke()
        }
        objc_setAssociatedObject(
            action,
            &_UIHostingMenuAssociatedKeys.wrappedActionKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    private func actionDidInvoke() {
        setNeedsUpdate()
        refreshVisibleMenuIfNeeded()
    }

    private func refreshVisibleMenuIfNeeded() {
        guard let interaction = _UIHostingMenuInteractionRuntime.activeInteraction else { return }
        guard _UIHostingMenuIntrospection.hasVisibleMenu(interaction: interaction) else {
            _UIHostingMenuInteractionRuntime.clearActiveInteraction(ifMatching: interaction)
            return
        }

        prewarmTask?.cancel()
        guard let refreshedMenu = try? concreteMenu(at: preferredBuildLocation) else {
            return
        }
        cachedMenu = refreshedMenu
        lastConcreteMenu = refreshedMenu
        _ = _UIHostingMenuIntrospection.updateVisibleMenu(interaction: interaction) { _ in
            refreshedMenu
        }
    }
}

@MainActor
private enum _UIHostingMenuBridge {
    private static var retainedHostKey: UInt8 = 0

    static func makeProbeRootView<Content: View>(rootView: Content) -> AnyView {
        AnyView(_ContextMenuProbeView(menuItems: rootView))
    }

    static func makeConcreteMenu(
        using host: _MenuHost,
        at location: CGPoint
    ) throws -> UIMenu {
        let configuration = try host.makeConfiguration(at: location)
        guard let menu = menu(from: configuration) else {
            throw UIHostingMenuError.menuBuildFailed
        }

        objc_setAssociatedObject(menu, &retainedHostKey, host, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return menu
    }

    static func menu(from configuration: UIContextMenuConfiguration) -> UIMenu? {
        guard let actionProvider = actionProvider(from: configuration),
              let menu = actionProvider([])
        else {
            return nil
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
    private final class _SyntheticContextMenuDelegate: NSObject, UIContextMenuInteractionDelegate {
        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            nil
        }
    }

    fileprivate let hostingController: UIHostingController<AnyView>
    private let containerController = UIViewController()
    private var window: UIWindow?
    private var didMount = false
    private let syntheticInteractionDelegate = _SyntheticContextMenuDelegate()
    private lazy var syntheticInteraction = UIContextMenuInteraction(delegate: syntheticInteractionDelegate)

    init(rootView: AnyView) {
        self.hostingController = UIHostingController(rootView: rootView)
        super.init()
    }

    func updateRootView(_ rootView: AnyView) {
        hostingController.rootView = rootView
        guard didMount else { return }
        containerController.view.setNeedsLayout()
        hostingController.view.setNeedsLayout()
        containerController.view.layoutIfNeeded()
        hostingController.view.layoutIfNeeded()
    }

    func mountIfNeeded() {
        guard !didMount else {
            ensureSyntheticInteractionInstalled()
            return
        }
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

        ensureSyntheticInteractionInstalled()
    }

    func detachWindow() {
        if let view = syntheticInteraction.view {
            view.removeInteraction(syntheticInteraction)
        }
        guard let window else { return }
        window.isHidden = true
        window.rootViewController = nil
        self.window = nil
    }

    func makeConfiguration(at location: CGPoint) throws -> UIContextMenuConfiguration {
        mountIfNeeded()
        ensureSyntheticInteractionInstalled()
        _ = driveRenderCycle()

        guard let bridge = findAnyContextMenuBridge() else {
#if DEBUG
            debugBridgeDiagnostics()
#endif
            throw UIHostingMenuError.contextMenuBridgeNotFound
        }

        guard let configuration = configuration(
            from: bridge,
            interaction: syntheticInteraction,
            at: location
        ) else {
#if DEBUG
            debugBridgeDiagnostics()
#endif
            throw UIHostingMenuError.configurationBuildFailed
        }

        return configuration
    }

    @discardableResult
    func driveRenderCycle() -> Bool {
        guard let hostView = hostingController.view else {
            return false
        }
        guard let driver = _SwiftUIPrivateRuntime.renderDriver(
            hostView: hostView,
            hostingController: hostingController
        ) else {
            return false
        }

        driver.setNeedsUpdate()
        driver.renderForPreferences(false)
        driver.preferencesDidChange()
        driver.didRenderHostingView()
        driver.didRenderHostingController()
        return true
    }

    fileprivate var hasSyntheticInteractionAttachedForTesting: Bool {
        syntheticInteraction.view === hostingController.view
    }

    private func ensureSyntheticInteractionInstalled() {
        guard syntheticInteraction.view == nil,
              let hostView = hostingController.view
        else {
            return
        }
        hostView.addInteraction(syntheticInteraction)
    }

    private func findContextMenuBridge(from root: Any) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        return firstObject(in: root, depth: 0, visited: &visited) { object in
            NSStringFromClass(type(of: object)).contains(
                _UIHostingMenuSelectorCatalog.RuntimeStrings.contextMenuBridgeClassFragment
            )
        } as? NSObject
    }

    private func findAnyContextMenuBridge() -> NSObject? {
        guard !isLookupForcedToFail else { return nil }
        if let bridge = bridgeBySelector(from: hostingController.view) {
            return bridge
        }
        if let bridge = findContextMenuBridgeByIvar(in: hostingController.view as AnyObject) {
            return bridge
        }
        if let bridge = findContextMenuBridgeInViewTree(start: hostingController.view) {
            return bridge
        }
        if let bridge = findContextMenuBridgeByIvar(in: hostingController) {
            return bridge
        }
        return findContextMenuBridge(from: hostingController as Any)
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

    private func configuration(
        from bridge: NSObject,
        interaction: UIContextMenuInteraction,
        at location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let effectiveLocation = resolvedLocation(location, in: hostingController.view)
        let selector = _UIHostingMenuSelectorCatalog.ContextMenuCallbacks.configurationForMenuAtLocation
        guard bridge.responds(to: selector),
              let method = class_getInstanceMethod(type(of: bridge), selector)
        else {
            return nil
        }

        typealias Function = @convention(c) (AnyObject, Selector, UIContextMenuInteraction, CGPoint) -> AnyObject?
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return function(bridge, selector, interaction, effectiveLocation) as? UIContextMenuConfiguration
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
        depth: Int,
        visited: inout Set<ObjectIdentifier>,
        where predicate: (AnyObject) -> Bool
    ) -> AnyObject? {
        guard depth < 12 else { return nil }

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
            if let found = firstObject(in: child.value, depth: depth + 1, visited: &visited, where: predicate) {
                return found
            }
        }

        var parent = mirror.superclassMirror
        while let parentMirror = parent {
            for child in parentMirror.children {
                if let found = firstObject(in: child.value, depth: depth + 1, visited: &visited, where: predicate) {
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

@MainActor
private enum _UIHostingMenuInteractionRuntime {
    static var didInstallHooks = false
    static weak var activeInteraction: UIContextMenuInteraction?
#if DEBUG
    static var testingHasVisibleMenu: ((UIContextMenuInteraction) -> Bool)?
    static var testingUpdateVisibleMenu: ((UIContextMenuInteraction, @escaping (UIMenu) -> UIMenu) -> Bool)?
#endif

    static func activateIfNeeded() {
        guard !didInstallHooks else { return }
        didInstallHooks = true
        _ = _UIContextMenuInteractionUIHostingMenuSwizzler.install()
    }

    static func menuWillDisplay(_ interaction: UIContextMenuInteraction) {
        activeInteraction = interaction
    }

    static func menuWillEnd(_ interaction: UIContextMenuInteraction) {
        clearActiveInteraction(ifMatching: interaction)
    }

    static func clearActiveInteraction(ifMatching interaction: UIContextMenuInteraction) {
        guard activeInteraction === interaction else { return }
        activeInteraction = nil
    }
}

private enum _UIContextMenuInteractionUIHostingMenuSwizzler {
    static func install() -> Bool {
        let willDisplay = swizzle(
            UIContextMenuInteraction.self,
            original: NSSelectorFromString("_delegate_contextMenuInteractionWillDisplayForConfiguration:"),
            swizzled: #selector(UIContextMenuInteraction._uihm_delegate_contextMenuInteractionWillDisplayForConfiguration(_:))
        )
        let willEnd = swizzle(
            UIContextMenuInteraction.self,
            original: NSSelectorFromString("_delegate_contextMenuInteractionWillEndForConfiguration:presentation:"),
            swizzled: #selector(UIContextMenuInteraction._uihm_delegate_contextMenuInteractionWillEndForConfiguration(_:presentation:))
        )
        return willDisplay && willEnd
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

private extension UIContextMenuInteraction {
    @objc func _uihm_delegate_contextMenuInteractionWillDisplayForConfiguration(
        _ configuration: AnyObject?
    ) -> AnyObject? {
        let result = _uihm_delegate_contextMenuInteractionWillDisplayForConfiguration(configuration)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                _UIHostingMenuInteractionRuntime.menuWillDisplay(self)
            }
        }
        return result
    }

    @objc func _uihm_delegate_contextMenuInteractionWillEndForConfiguration(
        _ configuration: AnyObject?,
        presentation: AnyObject?
    ) -> AnyObject? {
        let result = _uihm_delegate_contextMenuInteractionWillEndForConfiguration(configuration, presentation: presentation)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                _UIHostingMenuInteractionRuntime.menuWillEnd(self)
            }
        }
        return result
    }
}

#if DEBUG
@MainActor
enum _UIHostingMenuLiveTesting {
    static var forceContextMenuLookupFailure = false

    static func setForceDisableRenderDriver(_ disabled: Bool) {
        _SwiftUIPrivateRuntime.forceDisableRenderDriver = disabled
    }

    static func setForceContextMenuLookupFailure(_ forced: Bool) {
        forceContextMenuLookupFailure = forced
    }

    static func privateHookResolutionStatus() -> [String: Bool] {
        let host = _MenuHost(rootView: AnyView(EmptyView()))
        host.mountIfNeeded()
        let status = _SwiftUIPrivateRuntime.resolutionStatus(
            hostView: host.hostingController.view,
            hostingController: host.hostingController
        )
        host.detachWindow()
        return status
    }

    static func hasWarmCache<Content: View>(for menu: UIHostingMenu<Content>) -> Bool {
        menu.hasWarmCacheForTesting
    }

    static func makeConfiguration<Content: View>(
        from menu: UIHostingMenu<Content>,
        at location: CGPoint = CGPoint(x: 0.5, y: 0.5)
    ) throws -> UIContextMenuConfiguration {
        let host = _MenuHost(rootView: menu._uiHostingMenuProbeRootView())
        host.mountIfNeeded()
        do {
            let configuration = try host.makeConfiguration(at: location)
            host.detachWindow()
            return configuration
        } catch {
            host.detachWindow()
            throw error
        }
    }

    static func menuTitles(from configuration: UIContextMenuConfiguration) -> [String] {
        guard let menu = _UIHostingMenuBridge.menu(from: configuration) else {
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

    static func syntheticInteractionIsInstalled<Content: View>(for menu: UIHostingMenu<Content>) -> Bool {
        let host = _MenuHost(rootView: menu._uiHostingMenuProbeRootView())
        host.mountIfNeeded()
        let installed = host.hasSyntheticInteractionAttachedForTesting
        host.detachWindow()
        return installed
    }

    static func menuTitles(from menu: UIMenu) -> [String] {
        resolvedElements(from: menu.children).compactMap { element in
            if let action = element as? UIAction {
                return action.title
            }
            if let submenu = element as? UIMenu {
                return submenu.title
            }
            return nil
        }
    }

    static func firstAction(from menu: UIMenu) -> UIAction? {
        resolvedElements(from: menu.children).compactMap { $0 as? UIAction }.first
    }

    static func resolvedInlineGroups(from menu: UIMenu) -> [UIMenu] {
        resolvedElements(from: menu.children).compactMap { $0 as? UIMenu }
    }

    static func lastResolutionUsedWarmCache<Content: View>(for menu: UIHostingMenu<Content>) -> Bool {
#if DEBUG
        menu.lastResolutionUsedWarmCacheForTesting
#else
        false
#endif
    }

    static func setActiveInteraction(_ interaction: UIContextMenuInteraction?) {
        _UIHostingMenuInteractionRuntime.activeInteraction = interaction
    }

    static func installInteractionHooksIfNeeded() {
        _UIHostingMenuInteractionRuntime.activateIfNeeded()
    }

    static func setVisibleMenuSimulation(
        hasVisibleMenu: ((UIContextMenuInteraction) -> Bool)?,
        updateVisibleMenu: ((UIContextMenuInteraction, @escaping (UIMenu) -> UIMenu) -> Bool)?
    ) {
        _UIHostingMenuInteractionRuntime.testingHasVisibleMenu = hasVisibleMenu
        _UIHostingMenuInteractionRuntime.testingUpdateVisibleMenu = updateVisibleMenu
    }

    private static func resolvedElements(from elements: [UIMenuElement]) -> [UIMenuElement] {
        elements.flatMap { element in
            if let deferred = element as? UIDeferredMenuElement {
                let fulfilled = resolveDeferredElements(from: deferred)
                return resolvedElements(from: fulfilled)
            }

            if let submenu = element as? UIMenu {
                let children = resolvedElements(from: submenu.children)
                let rebuilt = UIMenu(
                    title: submenu.title,
                    subtitle: submenu.subtitle,
                    image: submenu.image,
                    identifier: submenu.identifier,
                    options: submenu.options,
                    preferredElementSize: submenu.preferredElementSize,
                    children: children
                )
                return [rebuilt]
            }

            return [element]
        }
    }

    private static func resolveDeferredElements(from deferred: UIDeferredMenuElement) -> [UIMenuElement] {
        if let providerObject = objectIvarValue(
            from: deferred,
            ivarName: _UIHostingMenuSelectorCatalog.DeferredTesting.elementProviderIvar
        ),
           let rawBlock = objectValue(
                from: providerObject,
                selector: _UIHostingMenuSelectorCatalog.DeferredTesting.providerBlock
           ) {
            typealias Provider = @convention(block) (@escaping ([UIMenuElement]) -> Void) -> Void
            let provider = unsafeBitCast(rawBlock, to: Provider.self)
            var fulfilled = [UIMenuElement]()
            provider { elements in
                fulfilled = elements
            }
            if !fulfilled.isEmpty {
                return fulfilled
            }
        }

        let fulfilled = (objectValue(
            from: deferred,
            selector: _UIHostingMenuSelectorCatalog.DeferredTesting.swiftUIFulfilledElements
        ) as? [UIMenuElement]) ?? (objectValue(
            from: deferred,
            selector: _UIHostingMenuSelectorCatalog.DeferredTesting.fulfilledElements
        ) as? [UIMenuElement]) ?? []
        return fulfilled
    }

    private static func objectIvarValue(from object: AnyObject, ivarName: String) -> AnyObject? {
        guard let ivar = class_getInstanceVariable(type(of: object), ivarName) else {
            return nil
        }
        return object_getIvar(object, ivar) as AnyObject?
    }

    private static func objectValue(from object: AnyObject, selector: Selector) -> AnyObject? {
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
}
#endif

@MainActor
private enum _UIHostingMenuIntrospection {
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

    static func setActionHandler(
        for action: UIAction,
        handler: @escaping (UIAction) -> Void
    ) {
        let selector = NSSelectorFromString("setHandler:")
        guard action.responds(to: selector),
              let method = class_getInstanceMethod(type(of: action), selector)
        else {
            return
        }

        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias Handler = @convention(block) (UIAction) -> Void
        let implementation = method_getImplementation(method)
        let setter = unsafeBitCast(implementation, to: Setter.self)
        let block: Handler = { event in handler(event) }
        setter(action, selector, unsafeBitCast(block, to: AnyObject.self))
    }

    @MainActor
    static func hasVisibleMenu(interaction: UIContextMenuInteraction) -> Bool {
#if DEBUG
        if let override = _UIHostingMenuInteractionRuntime.testingHasVisibleMenu {
            return override(interaction)
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

    @MainActor
    static func updateVisibleMenu(
        interaction: UIContextMenuInteraction,
        block: @escaping (UIMenu) -> UIMenu
    ) -> Bool {
#if DEBUG
        if let override = _UIHostingMenuInteractionRuntime.testingUpdateVisibleMenu {
            return override(interaction, block)
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
#endif
