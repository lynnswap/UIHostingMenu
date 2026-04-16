import Testing
@testable import UIHostingMenu

import ObjectiveC.runtime
import SwiftUI
import UIKit

@MainActor
@Test("SwiftUI menu items can be materialized as UIMenu")
func buildsMenuFromSwiftUIMenuItems() throws {
    let sut = UIHostingMenu(menuItems: {
        Button("Refresh") {}
        Menu("More") {
            Button("Share") {}
            Button("Delete", role: .destructive) {}
        }
    })

    let menu = try sut.menu()

    let topLevelTitles = menu.children.compactMap { element -> String? in
        if let action = element as? UIAction { return action.title }
        if let submenu = element as? UIMenu { return submenu.title }
        return nil
    }

    #expect(topLevelTitles.contains("Refresh"))
    #expect(topLevelTitles.contains("More"))
}

@MainActor
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
    #expect(!(first === third))
}

@MainActor
@Test("UIHostingMenu rebuilds menu when requested location changes")
func rebuildsWhenLocationChanges() throws {
    let sut = UIHostingMenu(menuItems: {
        Button("A") {}
    })

    let first = try sut.menu(at: CGPoint(x: 1, y: 1))
    let second = try sut.menu(at: CGPoint(x: 2, y: 2))
    #expect(!(first === second))
}

@MainActor
@Test("Divider creates displayInline section boundaries")
func dividerCreatesInlineSections() throws {
    let sut = UIHostingMenu(menuItems: {
        Button("Top") {}
        Divider()
        Button("Bottom") {}
    })

    let menu = try sut.menu()
    let groups = menu.children.compactMap { $0 as? UIMenu }

    #expect(groups.count == 2)
    #expect(groups.allSatisfy { $0.options.contains(.displayInline) })
    guard groups.count == 2 else { return }

    let firstTitles = groups[0].children.compactMap { ($0 as? UIAction)?.title }
    let secondTitles = groups[1].children.compactMap { ($0 as? UIAction)?.title }
    #expect(firstTitles == ["Top"])
    #expect(secondTitles == ["Bottom"])
}

@MainActor
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
    let firstAction = try #require(menu.children.first as? UIAction)
    #expect(_invokeUIAction(firstAction))
    #expect(flag.didRun)
}

#if DEBUG
@MainActor
@Test("Preferred interaction can build a bridge-backed configuration without run loop pumping")
func preferredInteractionBuildsBridgeConfiguration() throws {
    let hostingMenu = UIHostingMenu(menuItems: {
        Button("Dynamic") {}
        Button("Secondary") {}
    })

    let button = UIButton(type: .system)
    button.frame = CGRect(x: 0, y: 0, width: 120, height: 44)

    let delegate = _PassiveContextMenuDelegate()
    let interaction = UIContextMenuInteraction(delegate: delegate)
    button.addInteraction(interaction)

    let configuration = try _UIHostingMenuLiveTesting.makeConfiguration(
        from: hostingMenu,
        at: CGPoint(x: 12, y: 12),
        preferredInteraction: interaction
    )
    let titles = _UIHostingMenuLiveTesting.menuTitles(from: configuration)

    #expect(titles.contains("Dynamic"))
    #expect(titles.contains("Secondary"))
}

@MainActor
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

@MainActor
@Test("UIHostingMenu-assigned UIButton is only live-targeted when runtime is available")
func uiHostingMenuAssignmentAttachesCoordinatorWhenSupported() throws {
    _UIHostingMenuLiveTesting.setForceDisableLiveUpdates(false)
    defer { _UIHostingMenuLiveTesting.setForceDisableLiveUpdates(false) }

    let hostingMenu = UIHostingMenu(menuItems: {
        Button("Dynamic") {}
    })
    let button = UIButton(type: .system)
    button.menu = try hostingMenu.menu()

    let attached = _UIHostingMenuLiveTesting.isCoordinatorAttached(to: button)
    if _UIHostingMenuLiveTesting.isLiveUpdateActive {
        #expect(attached)
    } else {
        #expect(!attached)
    }
}

@MainActor
@Test("Plain UIMenu assignment never installs UIHostingMenu live coordinator")
func plainMenuAssignmentDoesNotAttachCoordinator() {
    _UIHostingMenuLiveTesting.setForceDisableLiveUpdates(false)
    defer { _UIHostingMenuLiveTesting.setForceDisableLiveUpdates(false) }

    let button = UIButton(type: .system)
    button.menu = UIMenu(title: "Plain", children: [UIAction(title: "Static") { _ in }])

    #expect(!_UIHostingMenuLiveTesting.isCoordinatorAttached(to: button))
}

@MainActor
@Test("Static menu build remains available when live updates are force-disabled")
func staticBuildStillWorksWhenLiveUpdatesAreDisabled() throws {
    _UIHostingMenuLiveTesting.setForceDisableLiveUpdates(true)
    defer { _UIHostingMenuLiveTesting.setForceDisableLiveUpdates(false) }

    let hostingMenu = UIHostingMenu(menuItems: {
        Button("Run") {}
    })
    let button = UIButton(type: .system)
    button.menu = try hostingMenu.menu()

    #expect(button.menu != nil)
    #expect(!_UIHostingMenuLiveTesting.isCoordinatorAttached(to: button))
}
#endif

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
        guard let rawHandler = getter(action, handlerSelector) else {
            return false
        }
        let handler = unsafeBitCast(rawHandler, to: Handler.self)
        handler(action)
        return true
    }
    return false
}
