import Foundation

#if canImport(UIKit)
import ABIBridge
import ObjectiveC.runtime
import OSLog
import SwiftUI
import UIKit

/// Errors that can occur while preparing or materializing a hosted menu.
public enum UIHostingMenuError: Swift.Error, LocalizedError {
    /// The asynchronous method preparation has not completed.
    case notPrepared
    /// SwiftUI did not install a menu coordinator in the hidden host.
    case menuCoordinatorNotFound
    /// SwiftUI's coordinator did not produce a menu.
    case menuBuildFailed

    /// A localized description of the failure.
    public var errorDescription: String? {
        switch self {
        case .notPrepared:
            "The hosting menu is not ready. Wait for prepare() or try again later."
        case .menuCoordinatorNotFound:
            "SwiftUI did not install a menu coordinator in the hosting view."
        case .menuBuildFailed:
            "SwiftUI's menu coordinator did not produce a UIMenu."
        }
    }
}

/// Builds UIKit menus from SwiftUI menu content.
///
/// Preparation begins automatically during initialization. Once ready, menu
/// construction is synchronous. Call prepare() when you need to wait for readiness
/// before assigning a menu to a UIButton or UIBarButtonItem.
///
/// - Important: This type relies on undocumented SwiftUI runtime behavior.
@MainActor
public final class UIHostingMenu<Content: View> {
    /// The error type used for readiness and menu materialization failures.
    public typealias BuildError = UIHostingMenuError

    private let owner: _UIHostingMenuOwner<Content>

    /// The SwiftUI content used for subsequent menu requests.
    ///
    /// Replacing the root resets its local SwiftUI state and clears the cached
    /// snapshot. The host and its prepared coordinator methods are reused.
    public var rootView: Content {
        get { owner.rootView }
        set { owner.updateRootView(newValue) }
    }

    /// The latest concrete snapshot, or nil before a successful build or after
    /// replacing the root view.
    public var cachedMenu: UIMenu? { owner.cachedMenu }

    /// Creates a hosting menu and starts asynchronous method preparation.
    ///
    /// - Parameter rootView: The SwiftUI view declaring the menu items.
    public init(rootView: Content) {
        owner = _UIHostingMenuOwner(rootView: rootView)
    }

    /// Creates a hosting menu from a SwiftUI menu content builder.
    ///
    /// - Parameter menuItems: The builder declaring the menu items.
    public convenience init(@ViewBuilder menuItems: () -> Content) {
        self.init(rootView: menuItems())
    }

    /// Waits for the preparation started by initialization.
    ///
    /// Repeated calls reuse the same preparation. Menu construction and root
    /// replacement remain synchronous after this method returns.
    /// - Throws: A preparation failure or CancellationError if the caller is cancelled.
    public func prepare() async throws {
        try await owner.prepare()
    }

    /// Synchronously returns a UIKit menu for the current SwiftUI content.
    ///
    /// Repeated requests for the same root and location reuse the deferred shell.
    /// That shell resolves fresh content each time UIKit presents it.
    ///
    /// - Parameter location: The location associated with the menu request.
    /// - Returns: A menu assignable to UIKit menu presenters.
    /// - Throws: UIHostingMenuError.notPrepared while preparation is in progress,
    ///   or the underlying preparation or materialization error.
    public func menu(at location: CGPoint = CGPoint(x: 0.5, y: 0.5)) throws -> UIMenu {
        try owner.menu(at: location)
    }

    /// Replaces the root content and resets its local SwiftUI state.
    ///
    /// - Parameter rootView: The new menu content.
    public func updateRootView(_ rootView: Content) {
        owner.updateRootView(rootView)
    }
}

@MainActor
private final class _UIHostingMenuOwner<Content: View> {
    private(set) var rootView: Content
    private(set) var cachedMenu: UIMenu?
    private let host: _MenuHost
    private var preparationTask: Task<Void, Never>?
    private var preparationError: (any Error)?
    private weak var cachedShell: UIMenu?
    private var cachedLocation: CGPoint?
    private var session: _HostedMenuPresentationSession?

    init(rootView: Content) {
        self.rootView = rootView
        host = _MenuHost(rootView: AnyView(rootView))
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await host.prepare()
            } catch {
                preparationError = error
            }
            preparationTask = nil
        }
    }

    isolated deinit {
        preparationTask?.cancel()
        session?.finish()
    }

    func prepare() async throws {
        try Task.checkCancellation()
        if let task = preparationTask { await task.value }
        try Task.checkCancellation()
        try requirePrepared()
    }

    private func requirePrepared() throws {
        if let preparationError { throw preparationError }
        guard host.isPrepared else { throw UIHostingMenuError.notPrepared }
    }

    func updateRootView(_ rootView: Content) {
        session?.finish()
        self.rootView = rootView
        cachedMenu = nil
        cachedShell = nil
        host.updateRootView(AnyView(rootView))
    }

    func menu(at location: CGPoint) throws -> UIMenu {
        try requirePrepared()
        try _UIHostingMenuInteractionRuntime.activateIfNeeded()
        let concrete = try materialize()
        if let shell = cachedShell, cachedLocation == location, metadataMatches(shell, concrete) {
            return shell
        }
        let box = _WeakDeferredMenuElementBox()
        let deferred = UIDeferredMenuElement.uncached { [self, box] completion in
            let resolve = { @MainActor [self] in
                let presenter = _UIHostingMenuPresenterIntrospection.presentingInteraction(from: box.element)
                do {
                    let concrete = try materialize()
                    if session == nil {
                        session = _HostedMenuPresentationSession(host: host) { [weak self] menu in
                            self?.cachedMenu = menu
                        }
                    }
                    if let session {
                        try _UIHostingMenuInteractionRuntime.prepare(session, presenterHint: presenter)
                    }
                    completion(concrete.children)
                } catch {
                    _UIHostingMenuInteractionRuntime.reportFailure(error)
                    completion(cachedMenu?.children ?? [])
                }
            }
            if Thread.isMainThread {
                MainActor.assumeIsolated { resolve() }
            } else {
                Task { @MainActor in resolve() }
            }
        }
        box.element = deferred
        let shell = concrete.replacingChildren([deferred])
        cachedShell = shell
        cachedLocation = location
        return shell
    }

    private func materialize() throws -> UIMenu {
        let menu = try host.makeMenu()
        cachedMenu = menu
        return menu
    }

    private func metadataMatches(_ lhs: UIMenu, _ rhs: UIMenu) -> Bool {
        let dynamicPrefix = _UIHostingMenuSelectorCatalog.RuntimeStrings.dynamicMenuIdentifierPrefix
        let sameIdentifier = lhs.identifier == rhs.identifier
            || (lhs.identifier.rawValue.hasPrefix(dynamicPrefix) && rhs.identifier.rawValue.hasPrefix(dynamicPrefix))
        let sameImage = lhs.image === rhs.image || lhs.image?.isEqual(rhs.image) == true
        return lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
            && sameIdentifier && sameImage && lhs.options == rhs.options
            && lhs.preferredElementSize == rhs.preferredElementSize
    }
}

@MainActor
private final class _WeakDeferredMenuElementBox {
    weak var element: UIDeferredMenuElement?
}

@MainActor
private final class _MenuHost {
    private struct Methods {
        let render: NativeBoundSwiftMethod<Void, Bool>
        let makeMenu: NativeBoundSwiftMethod<UIMenu?>
        let willShow: NativeBoundSwiftMethod<Void, UIContextMenuInteraction>
        let willDismiss: NativeBoundSwiftMethod<Void>
    }

    private let hostingView: _UIHostingView<AnyView>
    private var methods: Methods?
    private var rootGeneration = 0
    private static var retainedHostKey: UInt8 = 0

    var isPrepared: Bool { methods != nil }

    init(rootView: AnyView) {
        hostingView = _UIHostingView(rootView: Self.menuRoot(rootView, generation: 0))
        hostingView.frame = CGRect(x: 0, y: 0, width: 240, height: 240)
    }

    // The view and bound UIKit receivers must be released on MainActor.
    isolated deinit {}

    private static func menuRoot(_ content: AnyView, generation: Int) -> AnyView {
        // Reset only the content identity, preserving the Menu's coordinator.
        AnyView(Menu {
            content.id(generation)
        } label: {
            Text(verbatim: "")
        })
    }

    func updateRootView(_ content: AnyView) {
        rootGeneration += 1
        hostingView.rootView = Self.menuRoot(content, generation: rootGeneration)
    }

    func prepare() async throws {
        let render = try await ABIRuntime.shared.object(hostingView).method(
            named: _UIHostingMenuSelectorCatalog.HostingView.render,
            as: ((Bool) -> Void).self
        )
        try Task.checkCancellation()
        // Evaluate the menu graph without attaching this view to a window.
        try unsafe render.unsafeInvoke(true)
        guard let button = menuButton(in: hostingView),
              let coordinator = button.allTargets.compactMap({ $0.base as? NSObject }).first(where: {
                  $0.responds(to: _UIHostingMenuSelectorCatalog.Coordinator.menuActionTriggered)
              })
        else { throw UIHostingMenuError.menuCoordinatorNotFound }

        let object = ABIRuntime.shared.object(coordinator)
        let makeMenu = try await object.method(
            named: _UIHostingMenuSelectorCatalog.Coordinator.makeMenu, as: (() -> UIMenu?).self
        )
        let willShow = try await object.method(
            named: _UIHostingMenuSelectorCatalog.Coordinator.willShow,
            as: ((UIContextMenuInteraction) -> Void).self
        )
        let willDismiss = try await object.method(
            named: _UIHostingMenuSelectorCatalog.Coordinator.willDismiss, as: (() -> Void).self
        )
        try Task.checkCancellation()
        methods = Methods(render: render, makeMenu: makeMenu, willShow: willShow, willDismiss: willDismiss)
    }

    func makeMenu() throws -> UIMenu {
        guard let methods else { throw UIHostingMenuError.notPrepared }
        try unsafe methods.render.unsafeInvoke(true)
#if DEBUG
        if let replacement = _UIHostingMenuLiveTesting.makeMenuOverride { return try replacement() }
#endif
        guard let menu = try unsafe methods.makeMenu.unsafeInvoke() else {
            throw UIHostingMenuError.menuBuildFailed
        }
        return retain(normalizing: menu)
    }

    func retain(normalizing menu: UIMenu) -> UIMenu {
        let normalized = _UIHostingMenuBridge.normalizeInlineSectionsIfNeeded(menu)
        objc_setAssociatedObject(normalized, &Self.retainedHostKey, self, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return normalized
    }

    func willShow(_ interaction: UIContextMenuInteraction) throws {
        guard let methods else { throw UIHostingMenuError.notPrepared }
        try unsafe methods.willShow.unsafeInvoke(interaction)
    }

    func willDismiss() throws {
        guard let methods else { return }
        try unsafe methods.willDismiss.unsafeInvoke()
    }

    private func menuButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for child in view.subviews {
            if let button = menuButton(in: child) { return button }
        }
        return nil
    }
}

@MainActor
private final class _HostedMenuPresentationSession {
    private let host: _MenuHost
    private let didBuild: @MainActor (UIMenu) -> Void
    private weak var interaction: UIContextMenuInteraction?

    init(host: _MenuHost, didBuild: @escaping @MainActor (UIMenu) -> Void) {
        self.host = host
        self.didBuild = didBuild
    }

    func activate(with interaction: UIContextMenuInteraction) throws {
        guard self.interaction !== interaction else { return }
        finish()
        self.interaction = interaction
        _UIHostingMenuInteractionRuntime.register(self, for: interaction)
        do {
            try host.willShow(interaction)
        } catch {
            self.interaction = nil
            _UIHostingMenuInteractionRuntime.remove(self, from: interaction)
            throw error
        }
    }

    func finish() {
        guard let interaction else { return }
        self.interaction = nil
        _UIHostingMenuInteractionRuntime.remove(self, from: interaction)
        do { try host.willDismiss() }
        catch { _UIHostingMenuInteractionRuntime.reportFailure(error) }
    }

    func record(_ menu: UIMenu) -> UIMenu {
        let normalized = host.retain(normalizing: menu)
        didBuild(normalized)
        return normalized
    }
}

@MainActor
private enum _UIHostingMenuInteractionRuntime {
    typealias MenuTransform = @convention(block) (UIMenu) -> UIMenu
    private static var hooks: [NativeObjCMethodHook]?
    static weak var presentingInteraction: UIContextMenuInteraction?
    private static let sessions = NSMapTable<UIContextMenuInteraction, _HostedMenuPresentationSession>(
        keyOptions: .weakMemory, valueOptions: .weakMemory
    )
    private nonisolated static let logger = Logger(subsystem: "UIHostingMenu", category: "Runtime")
#if DEBUG
    static var testingUpdateVisibleMenu: ((UIContextMenuInteraction, @escaping (UIMenu) -> UIMenu) -> Bool)?
#endif

    static func activateIfNeeded() throws {
        guard hooks == nil else { return }
        hooks = try unsafe ABIRuntime.shared.installHooks([
            unsafe .mainActorMethod(
                on: UIContextMenuInteraction.self,
                selector: _UIHostingMenuSelectorCatalog.InteractionRuntime.delegateConfigurationForMenuAtLocation,
                as: ((CGPoint) -> AnyObject?).self, onFailure: reportFailure
            ) { call, point in
                let result = try call.proceed(point)
                let interaction = try call.receiver as! UIContextMenuInteraction
                menuConfigurationDidReturn(interaction, hasConfiguration: result != nil)
                return result
            },
            unsafe .mainActorMethod(
                on: UIContextMenuInteraction.self,
                selector: _UIHostingMenuSelectorCatalog.InteractionRuntime.delegateContextMenuInteractionWillDisplayForConfiguration,
                as: ((AnyObject?) -> AnyObject?).self, onFailure: reportFailure
            ) { call, configuration in
                let result = try call.proceed(configuration)
                menuWillDisplay(try call.receiver as! UIContextMenuInteraction)
                return result
            },
            unsafe .mainActorMethod(
                on: UIContextMenuInteraction.self,
                selector: _UIHostingMenuSelectorCatalog.InteractionRuntime.delegateContextMenuInteractionWillEndForConfiguration,
                as: ((AnyObject?, AnyObject?) -> AnyObject?).self, onFailure: reportFailure
            ) { call, configuration, presentation in
                let result = try call.proceed(configuration, presentation)
                menuWillEnd(try call.receiver as! UIContextMenuInteraction)
                return result
            },
            unsafe .mainActorMethod(
                on: UIContextMenuInteraction.self,
                selector: _UIHostingMenuSelectorCatalog.InteractionRuntime.updateVisibleMenuWithBlock,
                as: ((@escaping MenuTransform) -> Void).self, onFailure: reportFailure
            ) { call, block in
                let interaction = try call.receiver as! UIContextMenuInteraction
                guard let session = sessions.object(forKey: interaction) else {
                    return try call.proceed(block)
                }
                // SwiftUI can deliver an update from inside menuWillShow.
                // Lifecycle callbacks own teardown; ending it here would reenter
                // the coordinator while it still holds exclusive access.
                let wrapped: MenuTransform = { current in
                    session.record(block(current))
                }
#if DEBUG
                if let update = testingUpdateVisibleMenu {
                    _ = update(interaction) { wrapped($0) }
                    return
                }
#endif
                try call.proceed(wrapped)
            }
        ])
    }

    static func prepare(_ session: _HostedMenuPresentationSession, presenterHint: UIContextMenuInteraction?) throws {
        if let interaction = presenterHint ?? presentingInteraction {
            try session.activate(with: interaction)
        }
    }

    static func register(_ session: _HostedMenuPresentationSession, for interaction: UIContextMenuInteraction) {
        if let previous = sessions.object(forKey: interaction), previous !== session { previous.finish() }
        sessions.setObject(session, forKey: interaction)
    }

    static func remove(_ session: _HostedMenuPresentationSession, from interaction: UIContextMenuInteraction) {
        if sessions.object(forKey: interaction) === session { sessions.removeObject(forKey: interaction) }
        if presentingInteraction === interaction { presentingInteraction = nil }
    }

    static func menuConfigurationDidReturn(_ interaction: UIContextMenuInteraction, hasConfiguration: Bool) {
        if hasConfiguration { presentingInteraction = interaction }
        else { menuWillEnd(interaction) }
    }

    static func menuWillDisplay(_ interaction: UIContextMenuInteraction) {
        presentingInteraction = interaction
    }

    static func menuWillEnd(_ interaction: UIContextMenuInteraction) {
        sessions.object(forKey: interaction)?.finish()
        if presentingInteraction === interaction { presentingInteraction = nil }
    }

    nonisolated static func reportFailure(_ error: any Error) {
        logger.error("Hosted menu operation failed: \(String(describing: error), privacy: .public)")
    }

#if DEBUG
    static func resetForTesting() {
        let active = sessions.objectEnumerator()?.allObjects as? [_HostedMenuPresentationSession] ?? []
        for session in active { session.finish() }
        sessions.removeAllObjects()
        presentingInteraction = nil
    }
#endif
}

@MainActor
private enum _UIHostingMenuPresenterIntrospection {
    static func presentingInteraction(from deferred: UIDeferredMenuElement?) -> UIContextMenuInteraction? {
        guard let deferred,
              let source = objectValue(from: deferred, selector: _UIHostingMenuSelectorCatalog.DeferredRuntime.presentationSourceItem)
        else { return nil }
        return contextMenuInteraction(from: source)
    }

    static func contextMenuInteraction(from source: AnyObject) -> UIContextMenuInteraction? {
        if let interaction = objectValue(from: source, selector: _UIHostingMenuSelectorCatalog.PresenterRuntime.privateContextMenuInteraction) as? UIContextMenuInteraction {
            return interaction
        }
        if let interaction = objectValue(from: source, selector: _UIHostingMenuSelectorCatalog.PresenterRuntime.contextMenuInteraction) as? UIContextMenuInteraction {
            return interaction
        }
        return (source as? UIView)?.interactions.compactMap { $0 as? UIContextMenuInteraction }.first
    }

    private static func objectValue(from object: AnyObject, selector: Selector) -> AnyObject? {
        guard let method = try? ABIRuntime.shared.object(object).method(selector: selector, as: (() -> AnyObject?).self) else { return nil }
        return try? unsafe method.unsafeInvoke()
    }
}

#if DEBUG
@MainActor
enum _UIHostingMenuLiveTesting {
    static var makeMenuOverride: (() throws -> UIMenu)?

    static func setForceMenuBuildFailure(_ forced: Bool) {
        makeMenuOverride = forced ? { throw UIHostingMenuError.menuBuildFailed } : nil
    }

    static func setActiveInteraction(_ interaction: UIContextMenuInteraction?) {
        if let interaction { _UIHostingMenuInteractionRuntime.menuWillDisplay(interaction) }
        else { _UIHostingMenuInteractionRuntime.resetForTesting() }
    }

    static func endInteraction(_ interaction: UIContextMenuInteraction) {
        _UIHostingMenuInteractionRuntime.menuWillEnd(interaction)
    }

    static func setConfigurationResult(_ interaction: UIContextMenuInteraction, hasConfiguration: Bool) {
        _UIHostingMenuInteractionRuntime.menuConfigurationDidReturn(interaction, hasConfiguration: hasConfiguration)
    }

    static func setVisibleMenuSimulation(
        updateVisibleMenu: ((UIContextMenuInteraction, @escaping (UIMenu) -> UIMenu) -> Bool)?
    ) {
        _UIHostingMenuInteractionRuntime.testingUpdateVisibleMenu = updateVisibleMenu
    }

    static func presenterInteraction(from sourceItem: AnyObject) -> UIContextMenuInteraction? {
        _UIHostingMenuPresenterIntrospection.contextMenuInteraction(from: sourceItem)
    }

    static func menuTitles(from menu: UIMenu) async -> [String] {
        await resolvedElements(from: menu.children).compactMap {
            if let action = $0 as? UIAction { return action.title }
            return ($0 as? UIMenu)?.title
        }
    }

    static func firstAction(from menu: UIMenu) async -> UIAction? {
        await resolvedElements(from: menu.children).compactMap { $0 as? UIAction }.first
    }

    static func resolvedInlineGroups(from menu: UIMenu) async -> [UIMenu] {
        await resolvedElements(from: menu.children).compactMap { $0 as? UIMenu }
    }

    private static func resolvedElements(from elements: [UIMenuElement]) async -> [UIMenuElement] {
        var result: [UIMenuElement] = []
        for element in elements {
            if let deferred = element as? UIDeferredMenuElement {
                let children = await resolve(deferred)
                result.append(contentsOf: await resolvedElements(from: children))
            } else if let menu = element as? UIMenu {
                let children = await resolvedElements(from: menu.children)
                result.append(menu.replacingChildren(children))
            } else {
                result.append(element)
            }
        }
        return result
    }

    private static func resolve(_ deferred: UIDeferredMenuElement) async -> [UIMenuElement] {
        typealias Provider = @convention(block) (@escaping ([UIMenuElement]) -> Void) -> Void
        do {
            let object = ABIRuntime.shared.object(deferred)
            let provider: Provider
            let ivar = _UIHostingMenuSelectorCatalog.DeferredTesting.elementProviderIvar
            if let block = try? object.value(forIvar: ivar, as: Provider.self) {
                provider = block
            } else {
                let providerObject = try object.value(forIvar: ivar, as: AnyObject.self)
                let getter = try ABIRuntime.shared.object(providerObject).method(
                    selector: _UIHostingMenuSelectorCatalog.DeferredTesting.providerBlock,
                    as: (() -> Provider).self
                )
                provider = try unsafe getter.unsafeInvoke()
            }
            return await withCheckedContinuation { continuation in
                provider { continuation.resume(returning: $0) }
            }
        } catch {
            _UIHostingMenuInteractionRuntime.reportFailure(error)
            return []
        }
    }
}
#endif

@MainActor
private enum _UIHostingMenuBridge {
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
#endif
