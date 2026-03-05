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
            return "SwiftUI.ContextMenuBridge was not found in hosting view."
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
private enum _UIHostingMenuBridge {
    private static var retainedHostKey: UInt8 = 0

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
        let wrapped = AnyView(_ContextMenuProbeView(menuItems: rootView))

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
        let selector = NSSelectorFromString("actionProvider")
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

    private static func normalizeInlineSectionsIfNeeded(_ menu: UIMenu) -> UIMenu {
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

        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    func detachWindow() {
        guard let window else { return }
        window.isHidden = true
        window.rootViewController = nil
        self.window = nil
    }

    func makeConfiguration(at location: CGPoint) throws -> UIContextMenuConfiguration {
        for _ in 0..<5 {
            if let interaction = findContextMenuInteraction(in: hostingController.view) {
                if let configuration = configuration(from: interaction, at: location) {
                    return configuration
                }
                if let explored = configurationBySearchingLocation(in: interaction) {
                    return explored
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        if let bridge = findContextMenuBridge(from: hostingController.view as Any) {
            let interaction = findInteraction(in: bridge) ?? fallbackInteraction
            if let configuration = configuration(from: bridge, interaction: interaction, at: location) {
                return configuration
            }
        }

        if let bridge = findContextMenuBridge(from: hostingController as Any) {
            let interaction = findInteraction(in: bridge) ?? fallbackInteraction
            if let configuration = configuration(from: bridge, interaction: interaction, at: location) {
                return configuration
            }
        }

        if let bridge = bridgeBySelector(from: hostingController.view) {
            let interaction = findInteraction(in: bridge) ?? fallbackInteraction
            if let configuration = configuration(from: bridge, interaction: interaction, at: location) {
                return configuration
            }
        }

        if let bridge = findContextMenuBridgeByIvar(in: hostingController.view as AnyObject) {
            let interaction = findInteraction(in: bridge) ?? fallbackInteraction
            if let configuration = configuration(from: bridge, interaction: interaction, at: location) {
                return configuration
            }
        }

        if let bridge = findContextMenuBridgeInViewTree(start: hostingController.view),
           let configuration = configuration(from: bridge, interaction: fallbackInteraction, at: location) {
            return configuration
        }

#if DEBUG
        debugBridgeDiagnostics()
#endif
        throw UIHostingMenuError.contextMenuBridgeNotFound
    }

    private func findContextMenuBridge(from root: Any) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        return firstObject(in: root, visited: &visited) { object in
            NSStringFromClass(type(of: object)).contains("ContextMenuBridge")
        } as? NSObject
    }

    private func bridgeBySelector(from rootView: UIView) -> NSObject? {
        let selector = NSSelectorFromString("contextMenuBridge")
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
                if !name.localizedCaseInsensitiveContains("contextMenuBridge") {
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

    private func configuration(
        from interaction: UIContextMenuInteraction,
        at location: CGPoint
    ) -> UIContextMenuConfiguration? {
        wireContextMenuBridgeIfNeeded(for: interaction)
        let effectiveLocation = resolvedLocation(location, in: interaction.view)
        let privateSelector = NSSelectorFromString("_delegate_configurationForMenuAtLocation:")
        if interaction.responds(to: privateSelector),
           let method = class_getInstanceMethod(type(of: interaction), privateSelector) {
            typealias Function = @convention(c) (AnyObject, Selector, CGPoint) -> AnyObject?
            let implementation = method_getImplementation(method)
            let function = unsafeBitCast(implementation, to: Function.self)
            if let configuration = function(interaction, privateSelector, effectiveLocation) as? UIContextMenuConfiguration {
                return configuration
            }
        }

        if let pending = configurationFromInteractionPresentation(interaction, location: effectiveLocation) {
            return pending
        }

        guard let delegate = interaction.delegate as AnyObject? else { return nil }
        return configuration(from: delegate, interaction: interaction, at: effectiveLocation)
    }

    private func configuration(
        from delegate: AnyObject,
        interaction: UIContextMenuInteraction,
        at location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let selector = NSSelectorFromString("contextMenuInteraction:configurationForMenuAtLocation:")
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
        let selector = NSSelectorFromString("contextMenuInteraction:configurationForMenuAtLocation:")
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

    private func configurationFromInteractionPresentation(
        _ interaction: UIContextMenuInteraction,
        location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let presentSelector = NSSelectorFromString("_presentMenuAtLocation:")
        if interaction.responds(to: presentSelector),
           let method = class_getInstanceMethod(type(of: interaction), presentSelector) {
            typealias Presenter = @convention(c) (AnyObject, Selector, CGPoint) -> Void
            let implementation = method_getImplementation(method)
            let presenter = unsafeBitCast(implementation, to: Presenter.self)
            presenter(interaction, presentSelector, location)
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        if let pending = objectValue(for: interaction, selectorName: "pendingConfiguration") as? UIContextMenuConfiguration {
            return pending
        }

        if let configurations = objectValue(for: interaction, selectorName: "configurationsByIdentifier") as? NSDictionary {
            for candidate in configurations.allValues {
                if let configuration = candidate as? UIContextMenuConfiguration {
                    return configuration
                }
            }
        }
        return nil
    }

    private func objectValue(for object: AnyObject, selectorName: String) -> AnyObject? {
        let selector = NSSelectorFromString(selectorName)
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
              NSStringFromClass(type(of: delegate)).contains("ContextMenuBridge"),
              let bridge = delegate as? NSObject
        else {
            return
        }

        _ = setObjectReference(bridge, selectorName: "setInteraction:", ivarName: "interaction", value: interaction)
        if let hostView = hostingController.view {
            _ = setObjectReference(bridge, selectorName: "setHost:", ivarName: "host", value: hostView)
        }
    }

    private func setObjectReference(
        _ object: NSObject,
        selectorName: String,
        ivarName: String,
        value: AnyObject
    ) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        if object.responds(to: selector),
           let method = class_getInstanceMethod(type(of: object), selector) {
            typealias Setter = @convention(c) (AnyObject, Selector, AnyObject) -> Void
            let implementation = method_getImplementation(method)
            let setter = unsafeBitCast(implementation, to: Setter.self)
            setter(object, selector, value)
            return true
        }

        var currentClass: AnyClass? = object_getClass(object)
        while let cls = currentClass {
            if let ivar = class_getInstanceVariable(cls, ivarName) {
                object_setIvar(object, ivar, value)
                return true
            }
            currentClass = class_getSuperclass(cls)
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

#if DEBUG
    private func debugBridgeDiagnostics() {
        guard let rootView = hostingController.view else { return }
        let rootClass = NSStringFromClass(type(of: rootView))
        let interactions = rootView.interactions.map { NSStringFromClass(type(of: $0)) }
        print("DEBUG UIHostingMenu: bridge resolution failed. root=\(rootClass), interactions=\(interactions)")
    }
#endif
}
