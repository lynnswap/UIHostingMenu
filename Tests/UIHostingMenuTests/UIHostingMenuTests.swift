#if canImport(UIKit)
import Testing
import ABIBridge
@testable import UIHostingMenu

import Observation
import SwiftUI
import UIKit

@Suite("UIHostingMenu", .serialized)
@MainActor
struct UIHostingMenuTestsSuite {
    @Test("One runtime preparation makes later menus of different content types synchronous")
    func preparesRuntimeForLaterMenus() async throws {
        try await UIHostingMenuRuntime.prepare()
        try await UIHostingMenuRuntime.prepare()

        let first = UIHostingMenu(rootView: Button("First") {})
        let second = UIHostingMenu(menuItems: {
            Button("Second") {}
            Menu("More") { Button("Nested") {} }
        })
        let firstShell = try first.menu()
        let secondShell = try second.menu()

        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: firstShell) == ["First"])
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: secondShell) == ["Second", "More"])
        #expect(try first.menu() === firstShell)
        #expect(try second.menu() === secondShell)
    }

    @Test("Menus created before runtime preparation also become synchronously usable")
    func preparesRuntimeForExistingMenus() async throws {
        let first = UIHostingMenu(rootView: Button("Existing first") {})
        let second = UIHostingMenu(rootView: Button("Existing second") {})
        try await UIHostingMenuRuntime.prepare()

        let firstShell = try first.menu()
        let secondShell = try second.menu()
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: firstShell) == ["Existing first"])
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: secondShell) == ["Existing second"])
    }

    @Test("Cancelling a runtime preparation waiter leaves later synchronous menus usable")
    func cancellingRuntimeWaiterPreservesPreparation() async throws {
        let waiter = Task { try await UIHostingMenuRuntime.prepare() }
        waiter.cancel()
        do {
            try await waiter.value
            Issue.record("The cancelled runtime waiter should report cancellation")
        } catch is CancellationError {}

        try await UIHostingMenuRuntime.prepare()
        let hostingMenu = UIHostingMenu(rootView: Button("Ready") {})
        let shell = try hostingMenu.menu()
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Ready"])
    }

    @Test("Preparation is shared and subsequent menu requests stay synchronous")
    func preparesOnceForSynchronousRequests() async throws {
        let hostingMenu = UIHostingMenu(rootView: Button("Ready") {})
        try await hostingMenu.prepare()
        try await hostingMenu.prepare()
        let first = try hostingMenu.menu()
        #expect(try hostingMenu.menu() === first)
    }

    @Test("Prepared methods keep separate menu hosts and their actions independent")
    func preparedMethodsKeepHostsIndependent() async throws {
        let first = UIHostingMenu(rootView: _StatefulLocalStateMenuView(seed: 10))
        let second = UIHostingMenu(rootView: _StatefulLocalStateMenuView(seed: 20))
        try await first.prepare()
        try await second.prepare()
        let firstShell = try first.menu()
        let secondShell = try second.menu()
        let firstAction = try #require(await _UIHostingMenuLiveTesting.firstAction(from: firstShell))

        #expect(_invokeUIAction(firstAction))
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: firstShell) == ["Value 11"])
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: secondShell) == ["Value 20"])

        first.updateRootView(_StatefulLocalStateMenuView(seed: 30))
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: try first.menu()) == ["Value 30"])
        let secondAction = try #require(await _UIHostingMenuLiveTesting.firstAction(from: secondShell))
        #expect(_invokeUIAction(secondAction))
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: secondShell) == ["Value 21"])
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: try first.menu()) == ["Value 30"])
    }

    @Test("Initialization prepares later synchronous requests automatically")
    func automaticallyPreparesLaterRequests() async throws {
        let hostingMenu = UIHostingMenu(rootView: Button("Automatic") {})
        for _ in 0..<1000 {
            do {
                let menu = try hostingMenu.menu()
                #expect(await _UIHostingMenuLiveTesting.menuTitles(from: menu) == ["Automatic"])
                return
            } catch UIHostingMenuError.notPrepared {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        Issue.record("Automatic menu preparation did not complete")
    }

    @Test("Cancelling a preparation waiter does not cancel shared preparation")
    func cancellingWaiterPreservesPreparation() async throws {
        let hostingMenu = UIHostingMenu(rootView: Button("Ready") {})
        let waiter = Task { try await hostingMenu.prepare() }
        waiter.cancel()
        do {
            try await waiter.value
            Issue.record("The cancelled waiter should report cancellation")
        } catch is CancellationError {}
        try await hostingMenu.prepare()
        let menu = try hostingMenu.menu()
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: menu) == ["Ready"])
    }

    @Test("Releasing the last shell releases the prepared host and observed model")
    func releasingShellReleasesPreparedHost() async throws {
        weak var observedModel: _CounterModel?
        var shell: UIMenu?
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(updateVisibleMenu: { _, block in
            _ = block(UIMenu(children: []))
            return true
        })
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(updateVisibleMenu: nil)
        }
        do {
            let model = _CounterModel()
            observedModel = model
            let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
            try await hostingMenu.prepare()
            shell = try hostingMenu.menu()
            _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
            #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell!) == ["Increment 0"])
        }
        #expect(observedModel != nil)
        shell = nil
        #expect(await _waitUntil { observedModel == nil })
    }

    @Test("Fresh hidden host materializes a menu without run loop pumping or presenter interaction")
    func buildsMenuFromFreshHiddenHost() async throws {
        let sut = UIHostingMenu(menuItems: {
            Button("Refresh") {}
            Menu("More") {
                Button("Share") {}
                Button("Delete", role: .destructive) {}
            }
        })
        try await sut.prepare()

        let menu = try sut.menu()
        let topLevelTitles = await _UIHostingMenuLiveTesting.menuTitles(from: menu)

        #expect(topLevelTitles.contains("Refresh"))
        #expect(topLevelTitles.contains("More"))
    }

    @Test("UIHostingMenu reuses its shell until rootView changes")
    func reusesShellUntilRootViewChanges() async throws {
        let sut = UIHostingMenu(rootView: Button("A") {})
        try await sut.prepare()

        let first = try sut.menu()
        let second = try sut.menu()
        #expect(first === second)

        sut.updateRootView(Button("B") {})
        let third = try sut.menu()
        #expect(first !== third)
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: third) == ["B"])
    }

    @Test("rootView update clears the public cached snapshot")
    func rootViewUpdateClearsCachedMenu() async throws {
        let sut = UIHostingMenu(rootView: Button("A") {})
        try await sut.prepare()

        _ = try sut.menu()
        #expect(sut.cachedMenu != nil)

        sut.updateRootView(Button("B") {})
        #expect(sut.cachedMenu == nil)
    }

    @Test("cachedMenu remains a concrete materialized snapshot")
    func cachedMenuRemainsConcreteSnapshot() async throws {
        let sut = UIHostingMenu(menuItems: {
            Button("Refresh") {}
            Menu("More") {
                Button("Share") {}
            }
        })
        try await sut.prepare()

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

    @Test("Deferred shell stays resolvable after UIHostingMenu deallocation")
    func deferredShellRetainsItsOwner() async throws {
        var hostingMenu: UIHostingMenu<AnyView>? = UIHostingMenu(rootView: AnyView(Button("Ephemeral") {}))
        try await hostingMenu!.prepare()
        let shell = try hostingMenu!.menu()
        hostingMenu = nil
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Ephemeral"])
    }

    @Test("UIHostingMenu rebuilds menu when requested location changes")
    func rebuildsWhenLocationChanges() async throws {
        let sut = UIHostingMenu(menuItems: {
            Button("A") {}
        })
        try await sut.prepare()

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
        try await sut.prepare()

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
        try await sut.prepare()

        let menu = try sut.menu()
        let firstAction = try #require(await _UIHostingMenuLiveTesting.firstAction(from: menu))
        #expect(_invokeUIAction(firstAction))
        #expect(flag.didRun)
    }

    @Test("Declined presenter configuration does not attach a visible menu session")
    func declinedPresenterConfigurationDoesNotAttachVisibleMenuSession() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        try await hostingMenu.prepare()
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let shell = try hostingMenu.menu()
        var updatedTitles = [[String]]()

        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
            updateVisibleMenu: { _, block in
                let updated = block(UIMenu(children: []))
                updatedTitles.append(updated.children.compactMap { ($0 as? UIAction)?.title })
                return true
            }
        )
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
                updateVisibleMenu: nil
            )
        }

        _UIHostingMenuLiveTesting.setConfigurationResult(interaction, hasConfiguration: false)
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 0"])

        model.value = 1
        for _ in 0..<5 {
            await Task.yield()
        }
        #expect(updatedTitles.isEmpty)
    }

    @Test("External Observable mutation refreshes the visible menu without manual invalidation")
    func externalObservableMutationRefreshesVisibleMenuWithoutManualInvalidation() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        try await hostingMenu.prepare()
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let shell = try hostingMenu.menu()
        var updatedTitles = [[String]]()

        _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
            updateVisibleMenu: { _, block in
                let updated = block(UIMenu(children: []))
                updatedTitles.append(updated.children.compactMap { ($0 as? UIAction)?.title })
                return true
            }
        )
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
                updateVisibleMenu: nil
            )
        }

        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 0"])
        updatedTitles.removeAll()

        model.value = 4

        let didUpdate = await _waitUntil {
            updatedTitles.contains(["Increment 4"])
        }
        #expect(didUpdate)
    }

    @Test("Sequential visible UIHostingMenu sessions do not leak updates")
    func sequentialVisibleSessionsDoNotLeakUpdates() async throws {
        let firstModel = _CounterModel()
        let secondModel = _CounterModel()
        let firstMenu = UIHostingMenu(rootView: _CounterMenuView(model: firstModel))
        try await firstMenu.prepare()
        let secondMenu = UIHostingMenu(rootView: _CounterMenuView(model: secondModel))
        try await secondMenu.prepare()
        let firstInteraction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let secondInteraction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let firstShell = try firstMenu.menu()
        let secondShell = try secondMenu.menu()
        var updatedTitles = [ObjectIdentifier: [[String]]]()

        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
            updateVisibleMenu: { interaction, block in
                let updated = block(UIMenu(children: []))
                let titles = updated.children.compactMap { ($0 as? UIAction)?.title }
                updatedTitles[ObjectIdentifier(interaction), default: []].append(titles)
                return true
            }
        )
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
                updateVisibleMenu: nil
            )
        }

        _UIHostingMenuLiveTesting.setActiveInteraction(firstInteraction)
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: firstShell) == ["Increment 0"])
        updatedTitles.removeAll()

        firstModel.value = 1
        #expect(await _waitUntil {
            updatedTitles[ObjectIdentifier(firstInteraction)]?.contains(["Increment 1"]) == true
        })
        #expect(updatedTitles[ObjectIdentifier(secondInteraction)] == nil)

        _UIHostingMenuLiveTesting.setActiveInteraction(nil)
        updatedTitles.removeAll()

        firstModel.value = 2
        for _ in 0..<5 {
            await Task.yield()
        }
        #expect(updatedTitles.isEmpty)

        _UIHostingMenuLiveTesting.setActiveInteraction(secondInteraction)
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: secondShell) == ["Increment 0"])
        updatedTitles.removeAll()

        secondModel.value = 2
        #expect(await _waitUntil {
            updatedTitles[ObjectIdentifier(secondInteraction)]?.contains(["Increment 2"]) == true
        })
        #expect(updatedTitles[ObjectIdentifier(firstInteraction)] == nil)
    }

    @Test("An unrelated presentation does not adopt an active hosted session")
    func unrelatedPresentationDoesNotAdoptHostedSession() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        try await hostingMenu.prepare()
        let hostedInteraction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let ordinaryInteraction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        var updates: [ObjectIdentifier: [String]] = [:]
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(updateVisibleMenu: { interaction, block in
            let menu = block(UIMenu(children: []))
            updates[ObjectIdentifier(interaction)] = menu.children.compactMap { ($0 as? UIAction)?.title }
            return true
        })
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(updateVisibleMenu: nil)
        }
        let shell = try hostingMenu.menu()
        _UIHostingMenuLiveTesting.setActiveInteraction(hostedInteraction)
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 0"])
        _UIHostingMenuLiveTesting.setActiveInteraction(ordinaryInteraction)
        model.value = 1
        #expect(await _waitUntil { updates[ObjectIdentifier(hostedInteraction)] == ["Increment 1"] })
        #expect(updates[ObjectIdentifier(ordinaryInteraction)] == nil)
    }

    @Test("Resolving a shell outside a presentation does not attach it to the next unrelated menu")
    func unpresentedShellDoesNotAdoptNextPresenter() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        try await hostingMenu.prepare()
        let ordinaryInteraction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let hostedInteraction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        var updates: [ObjectIdentifier: [String]] = [:]
        _UIHostingMenuLiveTesting.setActiveInteraction(nil)
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(updateVisibleMenu: { interaction, block in
            let menu = block(UIMenu(children: []))
            updates[ObjectIdentifier(interaction)] = menu.children.compactMap { ($0 as? UIAction)?.title }
            return true
        })
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(updateVisibleMenu: nil)
        }

        let shell = try hostingMenu.menu()
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 0"])
        _UIHostingMenuLiveTesting.setActiveInteraction(ordinaryInteraction)
        model.value = 1
        try await Task.sleep(for: .milliseconds(50))
        #expect(updates.isEmpty)

        _UIHostingMenuLiveTesting.setActiveInteraction(hostedInteraction)
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 1"])
        model.value = 2
        #expect(await _waitUntil { updates[ObjectIdentifier(hostedInteraction)] == ["Increment 2"] })
        #expect(updates[ObjectIdentifier(ordinaryInteraction)] == nil)
    }

    @Test("A released presenter can be replaced by a new presentation")
    func releasedPresenterCanBeReplaced() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        try await hostingMenu.prepare()
        let shell = try hostingMenu.menu()
        var interaction: UIContextMenuInteraction? = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        var updates: [ObjectIdentifier: [String]] = [:]
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(updateVisibleMenu: { source, block in
            updates[ObjectIdentifier(source)] = block(UIMenu(children: [])).children.compactMap { ($0 as? UIAction)?.title }
            return true
        })
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(updateVisibleMenu: nil)
        }
        _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 0"])
        interaction = nil
        let replacement = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        _UIHostingMenuLiveTesting.setActiveInteraction(replacement)
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 0"])
        model.value = 2
        #expect(await _waitUntil { updates[ObjectIdentifier(replacement)] == ["Increment 2"] })
    }

    @Test("Unread observable properties do not change the visible menu")
    func onlySwiftUIReadObservablePropertiesRefreshVisibleMenu() async throws {
        let model = _TitleOnlyModel()
        let hostingMenu = UIHostingMenu(rootView: _TitleOnlyMenuView(model: model))
        try await hostingMenu.prepare()
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let shell = try hostingMenu.menu()
        var updatedTitles = [[String]]()

        _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
            updateVisibleMenu: { _, block in
                let updated = block(UIMenu(children: []))
                updatedTitles.append(updated.children.compactMap { ($0 as? UIAction)?.title })
                return true
            }
        )
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
                updateVisibleMenu: nil
            )
        }

        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Title A"])
        updatedTitles.removeAll()

        model.unread = 1
        for _ in 0..<5 {
            await Task.yield()
        }
        #expect(updatedTitles.allSatisfy { $0 == ["Title A"] })

        model.title = "B"

        let didUpdate = await _waitUntil {
            updatedTitles.contains(["Title B"])
        }
        #expect(didUpdate)
    }

    @Test("Ending presentation stops visible updates and reopening reads latest state")
    func endedPresentationStopsVisibleUpdatesAndReopenReadsLatestState() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        try await hostingMenu.prepare()
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let shell = try hostingMenu.menu()
        var updatedTitles = [[String]]()

        _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
            updateVisibleMenu: { _, block in
                let updated = block(UIMenu(children: []))
                updatedTitles.append(updated.children.compactMap { ($0 as? UIAction)?.title })
                return true
            }
        )
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
                updateVisibleMenu: nil
            )
        }

        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 0"])
        updatedTitles.removeAll()

        model.value = 1
        #expect(await _waitUntil { updatedTitles.contains(["Increment 1"]) })

        _UIHostingMenuLiveTesting.endInteraction(interaction)
        _UIHostingMenuLiveTesting.endInteraction(interaction)
        updatedTitles.removeAll()
        model.value = 2
        for _ in 0..<5 {
            await Task.yield()
        }
        #expect(updatedTitles.isEmpty)

        let reopenInteraction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        _UIHostingMenuLiveTesting.setActiveInteraction(reopenInteraction)
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 2"])

        updatedTitles.removeAll()
        model.value = 3
        #expect(await _waitUntil { updatedTitles.contains(["Increment 3"]) })
        _UIHostingMenuLiveTesting.endInteraction(reopenInteraction)
    }

    @Test("Ended pending session does not attach to the next presenter")
    func endedPendingSessionDoesNotAttachToNextPresenter() async throws {
        let firstModel = _CounterModel()
        let secondModel = _CounterModel()
        let firstMenu = UIHostingMenu(rootView: _CounterMenuView(model: firstModel))
        try await firstMenu.prepare()
        let secondMenu = UIHostingMenu(rootView: _CounterMenuView(model: secondModel))
        try await secondMenu.prepare()
        let firstInteraction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let secondInteraction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let firstShell = try firstMenu.menu()
        let secondShell = try secondMenu.menu()
        var updatedTitles = [ObjectIdentifier: [[String]]]()

        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
            updateVisibleMenu: { interaction, block in
                let updated = block(UIMenu(children: []))
                let titles = updated.children.compactMap { ($0 as? UIAction)?.title }
                updatedTitles[ObjectIdentifier(interaction), default: []].append(titles)
                return true
            }
        )
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
                updateVisibleMenu: nil
            )
        }

        _UIHostingMenuLiveTesting.setActiveInteraction(firstInteraction)
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: firstShell) == ["Increment 0"])
        _UIHostingMenuLiveTesting.endInteraction(firstInteraction)
        updatedTitles.removeAll()

        _UIHostingMenuLiveTesting.setActiveInteraction(secondInteraction)
        firstModel.value = 1
        for _ in 0..<5 {
            await Task.yield()
        }
        #expect(updatedTitles.isEmpty)

        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: secondShell) == ["Increment 0"])
        updatedTitles.removeAll()

        secondModel.value = 2
        #expect(await _waitUntil {
            updatedTitles[ObjectIdentifier(secondInteraction)]?.contains(["Increment 2"]) == true
        })
        #expect(updatedTitles[ObjectIdentifier(firstInteraction)] == nil)
    }

    @Test("Invoking a menu action refreshes the visible menu snapshot")
    func invokingActionRefreshesVisibleMenuSnapshot() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        try await hostingMenu.prepare()
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let initialMenu = try hostingMenu.menu()
        var updatedTitles: [String] = []

        _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
            updateVisibleMenu: { _, block in
                let updated = block(UIMenu(children: []))
                updatedTitles = updated.children.compactMap { ($0 as? UIAction)?.title }
                return true
            }
        )
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
                updateVisibleMenu: nil
            )
        }
        let action = try #require(await _UIHostingMenuLiveTesting.firstAction(from: initialMenu))

        #expect(_invokeUIAction(action))
        #expect(model.value == 1)
        #expect(await _waitUntil { updatedTitles == ["Increment 1"] })
    }

    @Test("Native menu build failure surfaces a deterministic error")
    func bridgeLookupFailureReturnsExplicitError() async throws {
        _UIHostingMenuLiveTesting.setForceMenuBuildFailure(true)
        defer { _UIHostingMenuLiveTesting.setForceMenuBuildFailure(false) }

        let sut = UIHostingMenu(menuItems: {
            Button("Unavailable") {}
        })
        try await sut.prepare()

        do {
            _ = try sut.menu()
            Issue.record("Expected UIHostingMenuError.menuBuildFailed")
        } catch let error as UIHostingMenuError {
            switch error {
            case .menuBuildFailed:
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
        try await hostingMenu.prepare()
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let shell = try hostingMenu.menu()

        _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
        _UIHostingMenuLiveTesting.setForceMenuBuildFailure(true)
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setForceMenuBuildFailure(false)
        }

        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Stable"])
    }

    @Test("Same snapshot can be assigned to button and navigation item owners")
    func sameSnapshotCanBeAssignedAcrossOwners() async throws {
        let hostingMenu = UIHostingMenu(menuItems: {
            Button("Dynamic") {}
        })
        try await hostingMenu.prepare()

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
        try await hostingMenu.prepare()
        let shell = try hostingMenu.menu()

        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 0"])

        model.value = 3
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
        defer { _UIHostingMenuLiveTesting.setActiveInteraction(nil) }

        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 3"])
    }

    @Test("Visible update and reopen both use the same latest state")
    func visibleUpdateAndReopenUseLatestState() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        try await hostingMenu.prepare()
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let shell = try hostingMenu.menu()
        var updatedTitles: [String] = []

        _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
            updateVisibleMenu: { _, block in
                let updated = block(UIMenu(children: []))
                updatedTitles = updated.children.compactMap { ($0 as? UIAction)?.title }
                return true
            }
        )
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
                updateVisibleMenu: nil
            )
        }
        let action = try #require(await _UIHostingMenuLiveTesting.firstAction(from: shell))

        #expect(_invokeUIAction(action))
        #expect(await _waitUntil { updatedTitles == ["Increment 1"] })
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 1"])
    }

    @Test("Visible menu update failure still leaves reopen with latest state")
    func visibleMenuUpdateFailureStillLeavesReopenWithLatestState() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        try await hostingMenu.prepare()
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let shell = try hostingMenu.menu()
        var updateCalls = 0

        _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
            updateVisibleMenu: { _, _ in
                updateCalls += 1
                return false
            }
        )
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
                updateVisibleMenu: nil
            )
        }
        let action = try #require(await _UIHostingMenuLiveTesting.firstAction(from: shell))

        let previousUpdateCount = updateCalls
        #expect(_invokeUIAction(action))
        #expect(model.value == 1)
        #expect(await _waitUntil { updateCalls > previousUpdateCount })
        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 1"])
    }

    @Test("Visible refresh promotes the latest fallback snapshot")
    func visibleRefreshPromotesLatestFallbackSnapshot() async throws {
        let model = _CounterModel()
        let hostingMenu = UIHostingMenu(rootView: _CounterMenuView(model: model))
        try await hostingMenu.prepare()
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let shell = try hostingMenu.menu()

        _UIHostingMenuLiveTesting.setActiveInteraction(interaction)
        _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
            updateVisibleMenu: { _, block in
                _ = block(UIMenu(children: []))
                return true
            }
        )
        defer {
            _UIHostingMenuLiveTesting.setActiveInteraction(nil)
            _UIHostingMenuLiveTesting.setVisibleMenuSimulation(
                updateVisibleMenu: nil
            )
            _UIHostingMenuLiveTesting.setForceMenuBuildFailure(false)
        }
        let action = try #require(await _UIHostingMenuLiveTesting.firstAction(from: shell))

        #expect(_invokeUIAction(action))
        #expect(await _waitUntil {
            hostingMenu.cachedMenu?.children.compactMap { ($0 as? UIAction)?.title } == ["Increment 1"]
        })
        _UIHostingMenuLiveTesting.setForceMenuBuildFailure(true)

        #expect(await _UIHostingMenuLiveTesting.menuTitles(from: shell) == ["Increment 1"])
    }

    @Test("An ordinary UIKit menu configuration passes through the interaction hook")
    func preservesOrdinaryContextMenuConfiguration() async throws {
        let hostingMenu = UIHostingMenu(rootView: Button("Hosted") {})
        try await hostingMenu.prepare()
        _ = try hostingMenu.menu()
        _UIHostingMenuLiveTesting.setActiveInteraction(nil)
        defer { _UIHostingMenuLiveTesting.setActiveInteraction(nil) }
        let delegate = _FixedContextMenuDelegate()
        let interaction = UIContextMenuInteraction(delegate: delegate)
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        view.addInteraction(interaction)
        let configure = try ABIRuntime.shared.object(interaction).method(
            selector: _UIHostingMenuSelectorCatalog.InteractionRuntime.delegateConfigurationForMenuAtLocation,
            as: ((CGPoint) -> UIContextMenuConfiguration?).self
        )
        let result = try unsafe configure.unsafeInvoke(CGPoint(x: 20, y: 20))
        #expect(result === delegate.configuration)
    }

    @Test("Presenter introspection prefers a private context menu interaction property")
    func presenterIntrospectionPrefersPrivateContextMenuInteractionProperty() {
        let privateInteraction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let plainInteraction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let sourceItem = _DualContextMenuSourceItem(
            privateInteraction: privateInteraction,
            plainInteraction: plainInteraction
        )

        #expect(_UIHostingMenuLiveTesting.presenterInteraction(from: sourceItem) === privateInteraction)
    }

    @Test("Presenter introspection falls back to view interactions")
    func presenterIntrospectionFallsBackToViewInteractions() {
        let interaction = UIContextMenuInteraction(delegate: _PassiveContextMenuDelegate())
        let sourceView = UIView()
        sourceView.addInteraction(interaction)

        #expect(_UIHostingMenuLiveTesting.presenterInteraction(from: sourceView) === interaction)
    }

    @Test("SwiftUI menu roles, disabled state, and submenus materialize as UIKit elements")
    func swiftUIMenuTraitsMaterializeAsUIKitElements() async throws {
        let hostingMenu = UIHostingMenu(menuItems: {
            Button("Enabled") {}
            Button("Disabled") {}
                .disabled(true)
            Button("Delete", role: .destructive) {}
            Menu("Nested") {
                Button("Child") {}
            }
        })
        try await hostingMenu.prepare()

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
        try await hostingMenu.prepare()
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
@Observable
private final class _TitleOnlyModel {
    var title = "A"
    var unread = 0
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
private struct _TitleOnlyMenuView: View {
    var model: _TitleOnlyModel

    var body: some View {
        Button("Title \(model.title)") {}
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

private final class _DualContextMenuSourceItem: NSObject {
    private let privateInteraction: UIContextMenuInteraction
    private let plainInteraction: UIContextMenuInteraction

    init(
        privateInteraction: UIContextMenuInteraction,
        plainInteraction: UIContextMenuInteraction
    ) {
        self.privateInteraction = privateInteraction
        self.plainInteraction = plainInteraction
        super.init()
    }

    @objc(_contextMenuInteraction)
    func privateContextMenuInteraction() -> UIContextMenuInteraction {
        privateInteraction
    }

    @objc(contextMenuInteraction)
    func contextMenuInteraction() -> UIContextMenuInteraction {
        plainInteraction
    }
}

@MainActor
private func _invokeUIAction(_ action: UIAction) -> Bool {
    typealias Handler = @convention(block) (UIAction) -> Void
    let object = ABIRuntime.shared.object(action)
    if let getter = try? object.method(
        selector: _UIHostingMenuSelectorCatalog.BridgeAccessors.handler,
        as: (() -> Handler?).self
    ), let handler = try? unsafe getter.unsafeInvoke() {
        handler(action)
        return true
    }
    do {
        let send = try object.method(
            selector: _UIHostingMenuSelectorCatalog.ActionRuntime.sendAction,
            as: ((UIAction) -> Void).self
        )
        try unsafe send.unsafeInvoke(action)
        return true
    } catch { return false }
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

#if canImport(UIKit)
@MainActor
private final class _FixedContextMenuDelegate: NSObject, UIContextMenuInteractionDelegate {
    let configuration = UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
        UIMenu(children: [UIAction(title: "Ordinary") { _ in }])
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        configuration
    }
}
#endif
