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
    func buildsMenuFromFreshHiddenHost() throws {
        let sut = UIHostingMenu(menuItems: {
            Button("Refresh") {}
            Menu("More") {
                Button("Share") {}
                Button("Delete", role: .destructive) {}
            }
        })

        let menu = try sut.menu()
        let topLevelTitles = _UIHostingMenuLiveTesting.menuTitles(from: menu)

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
    func dividerCreatesInlineSections() throws {
        let sut = UIHostingMenu(menuItems: {
            Button("Top") {}
            Divider()
            Button("Bottom") {}
        })

        let menu = try sut.menu()
        let groups = _UIHostingMenuLiveTesting.resolvedInlineGroups(from: menu)

        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.options.contains(.displayInline) })
        guard groups.count == 2 else { return }

        let firstTitles = groups[0].children.compactMap { ($0 as? UIAction)?.title }
        let secondTitles = groups[1].children.compactMap { ($0 as? UIAction)?.title }
        #expect(firstTitles == ["Top"])
        #expect(secondTitles == ["Bottom"])
    }

    @Test("UIAction executes captured SwiftUI action")
    func actionExecutesHandler() throws {
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
        let firstAction = try #require(_UIHostingMenuLiveTesting.firstAction(from: menu))
        #expect(_invokeUIAction(firstAction))
        #expect(flag.didRun)
    }

    #if DEBUG
    @Test("Private hook resolver resolves required render hooks")
    func privateHookResolverResolvesRequiredHooks() {
        let status = _UIHostingMenuLiveTesting.privateHookResolutionStatus()
        #expect(status.count == 6)
        #expect(status.values.allSatisfy { $0 })
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
    func invokingActionRefreshesVisibleMenuSnapshot() throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let initialMenu = try hostingMenu.menu()
        let action = try #require(_UIHostingMenuLiveTesting.firstAction(from: initialMenu))
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

    @Test("Bridge-only fallback still materializes a menu when render driver is disabled")
    func renderDriverFallbackStillBuildsMenu() throws {
        _UIHostingMenuLiveTesting.setForceDisableRenderDriver(true)
        defer { _UIHostingMenuLiveTesting.setForceDisableRenderDriver(false) }

        let sut = UIHostingMenu(menuItems: {
            Button("Fallback") {}
        })

        let menu = try sut.menu()
        let titles = _UIHostingMenuLiveTesting.menuTitles(from: menu)
        #expect(titles == ["Fallback"])
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

    @Test("Same snapshot can be assigned to button and navigation item owners")
    func sameSnapshotCanBeAssignedAcrossOwners() throws {
        let hostingMenu = UIHostingMenu(menuItems: {
            Button("Dynamic") {}
        })

        let snapshot = try hostingMenu.menu()

        let button = UIButton(type: .system)
        button.menu = snapshot

        let navigationItem = UINavigationItem(title: "Menu")
        let barButtonItem = UIBarButtonItem(systemItem: .add, primaryAction: nil, menu: snapshot)
        navigationItem.rightBarButtonItem = barButtonItem

        let snapshotTitles = _UIHostingMenuLiveTesting.menuTitles(from: snapshot)
        let buttonTitles = button.menu.map { _UIHostingMenuLiveTesting.menuTitles(from: $0) }
        let barButtonTitles = navigationItem.rightBarButtonItem?.menu.map { _UIHostingMenuLiveTesting.menuTitles(from: $0) }

        #expect(buttonTitles == snapshotTitles)
        #expect(barButtonTitles == snapshotTitles)
    }

    @Test("Same shell resolves latest state after reopen without reassignment")
    func sameShellResolvesLatestStateAfterReopen() throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        let shell = try hostingMenu.menu()

        #expect(_UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 0"])

        model.value = 3
        hostingMenu.setNeedsUpdate()

        #expect(_UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 3"])
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

        let titles = _UIHostingMenuLiveTesting.menuTitles(from: shell)
        #expect(titles == ["Increment 2"])
        #expect(_UIHostingMenuLiveTesting.lastResolutionUsedWarmCache(for: hostingMenu))
    }

    @Test("Visible update and reopen both use the same latest state")
    func visibleUpdateAndReopenUseLatestState() throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let shell = try hostingMenu.menu()
        let action = try #require(_UIHostingMenuLiveTesting.firstAction(from: shell))
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
        #expect(_UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 1"])
    }

    @Test("UIButton presenter-specific hook methods are absent")
    func buttonPresenterHooksAreAbsent() {
        let selectors = [
            NSSelectorFromString("_uihm_setMenu:"),
            NSSelectorFromString("_uihm_contextMenuInteraction:configurationForMenuAtLocation:"),
            NSSelectorFromString("_uihm_contextMenuInteraction:previewForHighlightingMenuWithConfiguration:"),
            NSSelectorFromString("_uihm_contextMenuInteraction:previewForDismissingMenuWithConfiguration:")
        ]

        #expect(selectors.allSatisfy { class_getInstanceMethod(UIButton.self, $0) == nil })
    }
    #endif
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

    let sendActionSelector = NSSelectorFromString("sendAction:")
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
