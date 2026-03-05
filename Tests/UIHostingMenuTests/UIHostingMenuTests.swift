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
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    #expect(flag.didRun)
}

@MainActor
private func _invokeUIAction(_ action: UIAction) -> Bool {
    let handlerSelector = NSSelectorFromString("handler")
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
