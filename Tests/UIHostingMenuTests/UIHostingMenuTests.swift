import Testing
@testable import UIHostingMenu

import Observation
import ObjectiveC.runtime
import SwiftUI
import UIKit

@MainActor
@Test("install(on:) exposes the private async configuration selector on UIButton")
func installRespondsToPrivateAsyncSelector() async throws {
    let env = await _makeHostEnvironment()
    let sut = UIHostingMenu(menuItems: {
        Button("Dynamic") {}
    })

    try sut.install(on: env.button)

    #expect(env.button.responds(to: _UIHostingMenuLiveTesting.asyncConfigurationSelector))
    #expect(_UIHostingMenuLiveTesting.isCoordinatorAttached(to: env.button))
}

@MainActor
@Test("install(on:) installs a deferred placeholder menu")
func installUsesDeferredPlaceholderMenu() async throws {
    let env = await _makeHostEnvironment()
    let sut = UIHostingMenu(menuItems: {
        Button("Dynamic") {}
    })

    try sut.install(on: env.button)

    let placeholder = try #require(env.button.menu)
    #expect(placeholder.children.count == 1)
    #expect(placeholder.children.first is UIDeferredMenuElement)
}

@MainActor
@Test("private async selector materializes SwiftUI menu items")
func asyncSelectorBuildsConfigurationAndMenu() async throws {
    let env = await _makeHostEnvironment()
    let sut = UIHostingMenu(menuItems: {
        Button("Refresh") {}
        Menu("More") {
            Button("Share") {}
            Button("Delete", role: .destructive) {}
        }
    })

    try sut.install(on: env.button)

    let configuration = try #require(await _UIHostingMenuLiveTesting.makeConfiguration(on: env.button))
    let actionProvider = try #require(_actionProvider(from: configuration))
    let menu = try #require(actionProvider([]))

    let topLevelTitles = _topLevelTitles(in: menu)
    #expect(topLevelTitles.contains("Refresh"))
    #expect(topLevelTitles.contains("More"))
}

@MainActor
@Test("prepare(in:) caches synchronously until invalidated")
func prepareCachesUntilSetNeedsUpdate() async throws {
    let env = await _makeHostEnvironment()
    let sut = UIHostingMenu(menuItems: {
        Button("A") {}
    })

    let first = try await sut.prepare(in: env.button)
    let second = try sut.menu()
    #expect(first === second)

    sut.setNeedsUpdate()
    do {
        _ = try sut.menu()
        Issue.record("Expected menu() to fail after invalidation.")
    } catch let error as UIHostingMenuError {
        #expect(error == .menuNotPrepared)
    }

    let third = try await sut.prepare(in: env.button)
    #expect(!(first === third))
}

@MainActor
@Test("source-less synchronous menu() returns menuNotPrepared")
func sourceLessMenuRequiresPreparation() throws {
    let sut = UIHostingMenu(menuItems: {
        Button("A") {}
    })

    do {
        _ = try sut.menu()
        Issue.record("Expected menu() without prepare(in:) to fail.")
    } catch let error as UIHostingMenuError {
        #expect(error == .menuNotPrepared)
    }
}

@MainActor
@Test("prepare(in:) mounts inside the existing hierarchy without creating a new UIWindow")
func prepareDoesNotCreateNewWindow() async throws {
    let env = await _makeHostEnvironment()
    let sut = UIHostingMenu(menuItems: {
        Button("A") {}
    })

    let before = _windowCount()
    _ = try await sut.prepare(in: env.button)
    let after = _windowCount()

    #expect(after == before)
}

@MainActor
@Test("prepare(in:) falls back when source view is not attached yet")
func prepareFallsBackForDetachedSourceView() async throws {
    let sourceView = UIView(frame: CGRect(x: 0, y: 0, width: 160, height: 44))
    let sut = UIHostingMenu(menuItems: {
        Button("Detached") {}
    })

    let menu = try await sut.prepare(in: sourceView)
    #expect(_topLevelTitles(in: menu) == ["Detached"])
}

@MainActor
@Test("visible menu refresh uses updateVisibleMenuWithBlock after action execution")
func liveUpdateRefreshesVisibleMenu() async throws {
    _UIHostingMenuLiveTesting.resetVisibleMenuTracking()
    defer { _UIHostingMenuLiveTesting.resetVisibleMenuTracking() }

    let box = _ObservableMenuBox()

    let env = await _makeHostEnvironment()
    let sut = UIHostingMenu(rootView: _ObservableMenuItemsView(box: box))

    try sut.install(on: env.button)
    #expect(_UIHostingMenuLiveTesting.isLiveUpdateActive)

    let realInteraction = try #require(env.button.contextMenuInteraction)
    let configuration = try #require(await _UIHostingMenuLiveTesting.makeConfiguration(on: env.button))
    let actionProvider = try #require(_actionProvider(from: configuration))
    let initialMenu = try #require(actionProvider([]))

    _UIHostingMenuLiveTesting.setForcedVisibleMenu(initialMenu)

    _UIHostingMenuLiveTesting.markMenuVisible(
        on: env.button,
        interaction: realInteraction,
        configuration: configuration
    )

    let visibleAction = try #require(initialMenu.children.first as? UIAction)
    #expect(_invokeUIAction(visibleAction))
    await Task.yield()

    #expect(_UIHostingMenuLiveTesting.updateVisibleMenuCallCount == 1)
    let refreshedMenu = try #require(_UIHostingMenuLiveTesting.forcedVisibleMenu)
    #expect(_topLevelTitles(in: refreshedMenu) == ["After"])

    _UIHostingMenuLiveTesting.clearVisibleMenu(on: env.button)
}

@MainActor
private final class _HostEnvironment {
    let window: UIWindow
    let viewController = UIViewController()
    let button = UIButton(type: .system)

    init(window: UIWindow) {
        self.window = window

        viewController.loadViewIfNeeded()
        viewController.view.backgroundColor = .systemBackground

        button.configuration = .filled()
        button.configuration?.title = "Open"
        button.showsMenuAsPrimaryAction = true
        button.translatesAutoresizingMaskIntoConstraints = false

        viewController.view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: viewController.view.centerXAnchor),
            button.centerYAnchor.constraint(equalTo: viewController.view.centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 160),
            button.heightAnchor.constraint(equalToConstant: 44)
        ])

        window.rootViewController = viewController
        window.makeKeyAndVisible()
        viewController.view.layoutIfNeeded()
    }

}

@MainActor
@Observable
private final class _ObservableMenuBox {
    var title = "Before"
}

@MainActor
private struct _ObservableMenuItemsView: View {
    let box: _ObservableMenuBox

    var body: some View {
        Button(box.title) {
            box.title = "After"
        }
    }
}

@MainActor
private var _retainedHostEnvironments = [_HostEnvironment]()

@MainActor
private func _makeHostEnvironment() async -> _HostEnvironment {
    let window = _makeWindow()
    let environment = _HostEnvironment(window: window)
    _retainedHostEnvironments.append(environment)
    await Task.yield()
    return environment
}

@MainActor
private func _makeWindow() -> UIWindow {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let foreground = scenes.first(where: { $0.activationState == .foregroundActive }) {
        return UIWindow(windowScene: foreground)
    }
    if let inactive = scenes.first(where: { $0.activationState == .foregroundInactive }) {
        return UIWindow(windowScene: inactive)
    }
    return UIWindow(frame: UIScreen.main.bounds)
}

@MainActor
private func _windowCount() -> Int {
    UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .count
}

@MainActor
private func _actionProvider(
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
    guard let rawProvider = getter(configuration, selector) else {
        return nil
    }

    let provider = unsafeBitCast(rawProvider, to: Provider.self)
    return { suggested in provider(suggested) }
}

@MainActor
private func _topLevelTitles(in menu: UIMenu) -> [String] {
    menu.children.compactMap { element in
        if let action = element as? UIAction {
            return action.title
        }
        if let submenu = element as? UIMenu {
            return submenu.title
        }
        return nil
    }
}

@MainActor
private func _invokeUIAction(_ action: UIAction) -> Bool {
    let handlerSelector = _UIHostingMenuSelectorCatalog.BridgeAccessors.handler
    if action.responds(to: handlerSelector),
       let method = class_getInstanceMethod(type(of: action), handlerSelector) {
        typealias Getter = @convention(c) (AnyObject, Selector) -> AnyObject?
        typealias Handler = @convention(block) (UIAction) -> Void

        let implementation = method_getImplementation(method)
        let getter = unsafeBitCast(implementation, to: Getter.self)
        guard let rawHandler = getter(action, handlerSelector) else {
            return false
        }
        let handler = unsafeBitCast(rawHandler, to: Handler.self)
        handler(action)
        return true
    }
    return false
}
