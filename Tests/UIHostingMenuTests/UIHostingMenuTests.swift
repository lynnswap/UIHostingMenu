#if canImport(UIKit)
import Testing
@testable import UIHostingMenu

import Observation
import ObjectiveC.runtime
import SwiftUI
import UIKit

@Suite("UIHostingMenu", .serialized)
@MainActor
struct UIHostingMenuTestsSuite {
    @Test("Fresh hidden host materializes a menu without run loop pumping or presenter interaction")
    func buildsMenuFromFreshHiddenHost() async throws {
        let sut = UIHostingMenu(menuItems: {
            Button("Refresh") {}
            Menu("More") {
                Button("Share") {}
                Button("Delete", role: .destructive) {}
            }
        })

        let menu = try sut.menu()
        let topLevelTitles = await _UIHostingMenuLiveTesting.menuTitles(from: menu)

        #expect(topLevelTitles.contains("Refresh"))
        #expect(topLevelTitles.contains("More"))
    }

    @Test("UIHostingMenu caches result until invalidated")
    func cachesUntilSetNeedsUpdate() throws {
        let sut = UIHostingMenu(menuItems: {
            Button("A") {}
        })

        let first = try sut.menu()
        let second = try sut.menu()
        #expect(first === second)

        sut.setNeedsUpdate()
        let third = try sut.menu()
        #expect(first === third)
    }

    @Test("setNeedsUpdate clears the public cached snapshot")
    func setNeedsUpdateClearsCachedMenu() throws {
        let sut = UIHostingMenu(menuItems: {
            Button("A") {}
        })

        _ = try sut.menu()
        #expect(sut.cachedMenu != nil)

        sut.setNeedsUpdate()
        #expect(sut.cachedMenu == nil)
    }

    @Test("cachedMenu remains a concrete materialized snapshot")
    func cachedMenuRemainsConcreteSnapshot() throws {
        let sut = UIHostingMenu(menuItems: {
            Button("Refresh") {}
            Menu("More") {
                Button("Share") {}
            }
        })

        let shell = try sut.menu()
        let cachedMenu = try #require(sut.cachedMenu)
        let cachedTitles = cachedMenu.children.compactMap { element -> String? in
            if let action = element as? UIAction {
                return action.title
            }
            if let submenu = element as? UIMenu {
                return submenu.title
            }
            return nil
        }

        #expect(!(cachedMenu === shell))
        #expect(cachedTitles.contains("Refresh"))
        #expect(cachedTitles.contains("More"))
        #expect(cachedMenu.children.allSatisfy { !($0 is UIDeferredMenuElement) })
    }

    @Test("Deferred shell stays resolvable after temporary UIHostingMenu deallocation")
    func deferredShellRetainsItsOwner() async throws {
        let shell = try UIHostingMenu(menuItems: {
            Button("Ephemeral") {}
        }).menu()

        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Ephemeral"])
    }

    @Test("UIHostingMenu rebuilds menu when requested location changes")
    func rebuildsWhenLocationChanges() throws {
        let sut = UIHostingMenu(menuItems: {
            Button("A") {}
        })

        let first = try sut.menu(at: CGPoint(x: 0.4, y: 0.4))
        let second = try sut.menu(at: CGPoint(x: 0.6, y: 0.6))
        #expect(!(first === second))
    }

    @Test("Divider creates displayInline section boundaries")
    func dividerCreatesInlineSections() async throws {
        let sut = UIHostingMenu(menuItems: {
            Button("Top") {}
            Divider()
            Button("Bottom") {}
        })

        let menu = try sut.menu()
        let groups = await _UIHostingMenuLiveTesting.resolvedInlineGroups(from: menu)

        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.options.contains(.displayInline) })
        guard groups.count == 2 else { return }

        let firstTitles = groups[0].children.compactMap { ($0 as? UIAction)?.title }
        let secondTitles = groups[1].children.compactMap { ($0 as? UIAction)?.title }
        #expect(firstTitles == ["Top"])
        #expect(secondTitles == ["Bottom"])
    }

    @Test("UIAction executes captured SwiftUI action")
    func actionExecutesHandler() async throws {
        final class Flag {
            var didRun = false
        }
        let flag = Flag()

        let sut = UIHostingMenu(menuItems: {
            Button("Execute") {
                flag.didRun = true
            }
        })

        let menu = try sut.menu()
        let firstAction = try #require(await _UIHostingMenuLiveTesting.firstAction(from: menu))
        #expect(_invokeUIAction(firstAction))
        #expect(flag.didRun)
    }

    @Test("requestUpdate prewarms the next synchronous menu build")
    func requestUpdatePrewarmsNextBuild() async throws {
        let sut = UIHostingMenu(menuItems: {
            Button("Reload") {}
        })

        let first = try sut.menu()
        sut.requestUpdate()

        for _ in 0..<20 {
            if _UIHostingMenuLiveTesting.hasWarmCache(for: sut) {
                break
            }
            await Task.yield()
        }

        #expect(_UIHostingMenuLiveTesting.hasWarmCache(for: sut))
        let second = try sut.menu()
        #expect(first === second)
    }

    @Test("requestUpdate after delay keeps current snapshot until scheduled invalidation")
    func requestUpdateAfterDelayDefersInvalidation() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        let shell = try hostingMenu.menu()

        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 0"])

        model.value = 7
        hostingMenu.requestUpdate(after: 60)
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 0"])

        hostingMenu.requestUpdate(after: 0.01)
        let didUpdate = await _waitUntil {
            await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 7"]
        }
        #expect(didUpdate)
    }

    @Test("Hidden host synthetic interaction can build configuration without presenter interaction")
    func syntheticHiddenHostInteractionBuildsConfiguration() throws {
        let hostingMenu = UIHostingMenu(menuItems: {
            Button("Dynamic") {}
            Button("Secondary") {}
        })

        #expect(_UIHostingMenuLiveTesting.syntheticInteractionIsInstalled(for: hostingMenu))

        let configuration = try _UIHostingMenuLiveTesting.makeConfiguration(
            from: hostingMenu,
            at: CGPoint(x: 0.5, y: 0.5)
        )
        let titles = _UIHostingMenuLiveTesting.menuTitles(from: configuration)

        #expect(titles.contains("Dynamic"))
        #expect(titles.contains("Secondary"))
    }

    @Test("Invoking a menu action refreshes the visible menu snapshot")
    func invokingActionRefreshesVisibleMenuSnapshot() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let initialMenu = try hostingMenu.menu()
        let action = try #require(await _UIHostingMenuLiveTesting.firstAction(from: initialMenu))
        var updatedTitles: [String] = []

        _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
            hasVisibleMenu: { _ in true },
            updateVisibleMenu: { _, block in
                let updated = block(UIMenu(children: []))
                updatedTitles = updated.children.compactMap { ($0 as? UIAction)?.title }
                return true
            }
        )
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
                hasVisibleMenu: nil,
                updateVisibleMenu: nil
            )
        }

        #expect(_invokeUIAction(action))
        #expect(model.value == 1)
        #expect(updatedTitles == ["Increment 1"])
    }

    @Test("Hidden visible menu skips refresh and clears active interaction")
    func hiddenVisibleMenuSkipsRefreshAndClearsActiveInteraction() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let shell = try hostingMenu.menu()
        let action = try #require(await _UIHostingMenuLiveTesting.firstAction(from: shell))
        var reportsVisible = false
        var visibleChecks = 0
        var updateCalls = 0

        _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
            hasVisibleMenu: { _ in
                visibleChecks += 1
                return reportsVisible
            },
            updateVisibleMenu: { _, _ in
                updateCalls += 1
                return true
            }
        )
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
                hasVisibleMenu: nil,
                updateVisibleMenu: nil
            )
        }

        #expect(_invokeUIAction(action))
        #expect(model.value == 1)
        #expect(visibleChecks == 1)
        #expect(updateCalls == 0)

        reportsVisible = true
        #expect(_invokeUIAction(action))
        #expect(model.value == 2)
        #expect(visibleChecks == 1)
        #expect(updateCalls == 0)
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 2"])
    }

    @Test("Bridge lookup failure surfaces a deterministic error")
    func bridgeLookupFailureReturnsExplicitError() {
        _UIHostingMenuLiveTesting.setForceContextMenuLookupFailure(true)
        defer { _UIHostingMenuLiveTesting.setForceContextMenuLookupFailure(false) }

        let sut = UIHostingMenu(menuItems: {
            Button("Unavailable") {}
        })

        do {
            _ = try sut.menu()
            Issue.record("Expected UIHostingMenuError.contextMenuBridgeNotFound")
        } catch let error as UIHostingMenuError {
            switch error {
            case .contextMenuBridgeNotFound:
                break
            default:
                Issue.record("Unexpected UIHostingMenuError: \(error.localizedDescription)")
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Deferred reopen falls back to the last cached snapshot on rebuild failure")
    func deferredReopenFallsBackToLastCachedSnapshot() async throws {
        let hostingMenu = UIHostingMenu(menuItems: {
            Button("Stable") {}
        })
        let shell = try hostingMenu.menu()

        _UIHostingMenuLiveTesting.setForceContextMenuLookupFailure(true)
        defer { _UIHostingMenuLiveTesting.setForceContextMenuLookupFailure(false) }

        hostingMenu.setNeedsUpdate()
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Stable"])
    }

    @Test("Same snapshot can be assigned to button and navigation item owners")
    func sameSnapshotCanBeAssignedAcrossOwners() async throws {
        let hostingMenu = UIHostingMenu(menuItems: {
            Button("Dynamic") {}
        })

        let snapshot = try hostingMenu.menu()

        let button = UIButton(type: .system)
        button.menu = snapshot

        let navigationItem = UINavigationItem(title: "Menu")
        let barButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: nil, menu: snapshot)
        navigationItem.rightBarButtonItem = barButtonItem

        let snapshotTitles = await _UIHostingMenuLiveTesting.menuTitles(from: snapshot)
        let buttonTitles: [String]? = if let menu = button.menu {
            await _UIHostingMenuLiveTesting.menuTitles(from: menu)
        } else {
            nil
        }
        let barButtonTitles: [String]? = if let menu = navigationItem.rightBarButtonItem?.menu {
            await _UIHostingMenuLiveTesting.menuTitles(from: menu)
        } else {
            nil
        }

        #expect(buttonTitles == snapshotTitles)
        #expect(barButtonTitles == snapshotTitles)
    }

    @Test("Same shell resolves latest state after reopen without reassignment")
    func sameShellResolvesLatestStateAfterReopen() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        let shell = try hostingMenu.menu()

        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 0"])

        model.value = 3
        hostingMenu.setNeedsUpdate()

        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 3"])
    }

    @Test("Deferred fulfillment uses warm cache after requestUpdate")
    func deferredFulfillmentUsesWarmCacheAfterRequestUpdate() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        let shell = try hostingMenu.menu()

        model.value = 2
        hostingMenu.requestUpdate()

        for _ in 0..<20 {
            if _UIHostingMenuLiveTesting.hasWarmCache(for: hostingMenu) {
                break
            }
            await Task.yield()
        }

        let titles = await _UIHostingMenuLiveTesting.menuTitles(from: shell)
        #expect(titles == ["Increment 2"])
        #expect(_UIHostingMenuLiveTesting.lastResolutionUsedWarmCache(for: hostingMenu))
    }

    @Test("Visible update and reopen both use the same latest state")
    func visibleUpdateAndReopenUseLatestState() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let shell = try hostingMenu.menu()
        let action = try #require(await _UIHostingMenuLiveTesting.firstAction(from: shell))
        var updatedTitles: [String] = []

        _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
            hasVisibleMenu: { _ in true },
            updateVisibleMenu: { _, block in
                let updated = block(UIMenu(children: []))
                updatedTitles = updated.children.compactMap { ($0 as? UIAction)?.title }
                return true
            }
        )
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
                hasVisibleMenu: nil,
                updateVisibleMenu: nil
            )
        }

        #expect(_invokeUIAction(action))
        #expect(updatedTitles == ["Increment 1"])
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 1"])
    }

    @Test("Visible menu update failure still leaves reopen with latest state")
    func visibleMenuUpdateFailureStillLeavesReopenWithLatestState() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let shell = try hostingMenu.menu()
        let action = try #require(await _UIHostingMenuLiveTesting.firstAction(from: shell))
        var updateCalls = 0

        _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
            hasVisibleMenu: { _ in true },
            updateVisibleMenu: { _, _ in
                updateCalls += 1
                return false
            }
        )
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
                hasVisibleMenu: nil,
                updateVisibleMenu: nil
            )
        }

        #expect(_invokeUIAction(action))
        #expect(model.value == 1)
        #expect(updateCalls == 1)
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 1"])
    }

    @Test("Visible refresh promotes the latest fallback snapshot")
    func visibleRefreshPromotesLatestFallbackSnapshot() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let shell = try hostingMenu.menu()
        let action = try #require(await _UIHostingMenuLiveTesting.firstAction(from: shell))

        _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
            hasVisibleMenu: { _ in true },
            updateVisibleMenu: { _, block in
                _ = block(UIMenu(children: []))
                return true
            }
        )
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
                hasVisibleMenu: nil,
                updateVisibleMenu: nil
            )
            _UIHostingMenuLiveTesting.setForceContextMenuLookupFailure(false)
        }

        #expect(_invokeUIAction(action))
        _UIHostingMenuLiveTesting.setForceContextMenuLookupFailure(true)
        hostingMenu.setNeedsUpdate()

        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 1"])
    }

    @Test("UIButton presenter-specific hook methods are absent")
    func buttonPresenterHooksAreAbsent() {
        let selectors = [
            _UIHostingMenuSelectorCatalog.PresenterTesting.setMenu,
            _UIHostingMenuSelectorCatalog.PresenterTesting.configurationForMenuAtLocation,
            _UIHostingMenuSelectorCatalog.PresenterTesting.previewForHighlightingMenuWithConfiguration,
            _UIHostingMenuSelectorCatalog.PresenterTesting.previewForDismissingMenuWithConfiguration
        ]

        #expect(selectors.allSatisfy { class_getInstanceMethod(UIButton.self, $0) == nil })
    }

    @Test("SwiftUI menu roles, disabled state, and submenus materialize as UIKit elements")
    func swiftUIMenuTraitsMaterializeAsUIKitElements() throws {
        let hostingMenu = UIHostingMenu(menuItems: {
            Button("Enabled") {}
            Button("Disabled") {}
                .disabled(true)
            Button("Delete", role: .destructive) {}
            Menu("Nested") {
                Button("Child") {}
            }
        })

        _ = try hostingMenu.menu()
        let concreteMenu = try #require(hostingMenu.cachedMenu)
        let enabled = try #require(_firstAction(titled: "Enabled", in: concreteMenu))
        let disabled = try #require(_firstAction(titled: "Disabled", in: concreteMenu))
        let delete = try #require(_firstAction(titled: "Delete", in: concreteMenu))
        let nested = try #require(_firstMenu(titled: "Nested", in: concreteMenu))

        #expect(!enabled.attributes.contains(.disabled))
        #expect(disabled.attributes.contains(.disabled))
        #expect(delete.attributes.contains(.destructive))
        #expect(_firstAction(titled: "Child", in: nested) != nil)
    }

    @Test("Replacing rootView resets local SwiftUI state")
    func replacingRootViewResetsLocalSwiftUIState() async throws {
        let hostingMenu = UIHostingMenu(rootView: _StatefulLocalStateMenuView(seed: 0))
        let firstShell = try hostingMenu.menu()
        let firstAction = try #require(await _UIHostingMenuLiveTesting.firstAction(from: firstShell))

        #expect(_invokeUIAction(firstAction))
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: firstShell) == ["Value 1"])

        hostingMenu.updateRootView(_StatefulLocalStateMenuView(seed: 10))
        let secondShell = try hostingMenu.menu()

        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: secondShell) == ["Value 10"])
    }
}

@MainActor
@Observable
private final class _CounterModel {
    var value = 0
}

@MainActor
private struct _CounterMenuView: View {
    var model: _CounterModel

    var body: some View {
        Button("Increment \(model.value)") {
            model.value += 1
        }
        .menuActionDismissBehavior(.disabled)
    }
}

@MainActor
private struct _StatefulLocalStateMenuView: View {
    let seed: Int
    @State private var value: Int

    init(seed: Int) {
        self.seed = seed
        _value = State(initialValue: seed)
    }

    var body: some View {
        Button("Value \(value)") {
            value += 1
        }
        .menuActionDismissBehavior(.disabled)
    }
}

private final class _PassiveContextMenuDelegate: NSObject, UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        nil
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
        if let rawBlock = getter(action, handlerSelector) {
            let handler = unsafeBitCast(rawBlock, to: Handler.self)
            handler(action)
            return true
        }
    }

    let sendActionSelector = _UIHostingMenuSelectorCatalog.ActionRuntime.sendAction
    if action.responds(to: sendActionSelector),
       let method = class_getInstanceMethod(type(of: action), sendActionSelector) {
        typealias Sender = @convention(c) (AnyObject, Selector, UIAction) -> Void

        let implementation = method_getImplementation(method)
        let sender = unsafeBitCast(implementation, to: Sender.self)
        sender(action, sendActionSelector, action)
        return true
    }

    return false
}

@MainActor
private func _waitUntil(
    timeout: Int = 100,
    condition: @MainActor () async -> Bool
) async -> Bool {
    for _ in 0..<timeout {
        if await condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

@MainActor
private func _firstAction(titled title: String, in menu: UIMenu) -> UIAction? {
    for element in menu.children {
        if let action = element as? UIAction, action.title == title {
            return action
        }
        if let submenu = element as? UIMenu,
           let action = _firstAction(titled: title, in: submenu) {
            return action
        }
    }
    return nil
}

@MainActor
private func _firstMenu(titled title: String, in menu: UIMenu) -> UIMenu? {
    for element in menu.children {
        if let submenu = element as? UIMenu {
            if submenu.title == title {
                return submenu
            }
            if let nested = _firstMenu(titled: title, in: submenu) {
                return nested
            }
        }
    }
    return nil
}
#endif
