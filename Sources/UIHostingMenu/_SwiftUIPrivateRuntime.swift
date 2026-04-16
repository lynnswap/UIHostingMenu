import Foundation
import MachO
import MachOKit

private struct _SwiftUIPrivateHookSpec {
    let label: String
    let mangledNames: [String]
}

struct _SwiftUIResolvedHooks {
    typealias VoidHook = @convention(thin) (AnyObject) -> Void
    typealias DoubleHook = @convention(thin) (AnyObject, Double) -> Void
    typealias BoolHook = @convention(thin) (AnyObject, Bool) -> Void

    let setNeedsUpdate: VoidHook?
    let requestUpdateAfter: DoubleHook?
    let renderForPreferences: BoolHook?
    let preferencesDidChange: VoidHook?
    let didRenderHostingView: VoidHook?
    let didRenderHostingController: VoidHook?
    let missingHookLabels: [String]

    var canDriveRenderCycle: Bool {
        setNeedsUpdate != nil
            && renderForPreferences != nil
            && preferencesDidChange != nil
            && didRenderHostingView != nil
            && didRenderHostingController != nil
    }

    static func load() -> Self {
        let loadedImage = unsafe _SwiftUIPrivateRuntimeUnsafe.loadedSwiftUIImage()
        let loadedTextSegment = loadedImage.flatMap { unsafe _SwiftUIPrivateRuntimeUnsafe.textSegment(in: $0) }

        let cache = DyldCacheLoaded.current
        let cacheImage = unsafe _SwiftUIPrivateRuntimeUnsafe.cacheImage(in: cache)
        let cacheTextSegment = cacheImage.flatMap { unsafe _SwiftUIPrivateRuntimeUnsafe.textSegment(in: $0) }

        func resolve<T>(_ spec: _SwiftUIPrivateHookSpec, as type: T.Type) -> T? {
            _ = type

            for symbolName in spec.mangledNames {
                if let function: T = unsafe _SwiftUIPrivateRuntimeUnsafe.resolveLoadedImageFunction(
                    named: symbolName,
                    in: loadedImage,
                    text: loadedTextSegment,
                    as: T.self
                ) {
                    return function
                }
                if let function: T = unsafe _SwiftUIPrivateRuntimeUnsafe.resolveSharedCacheFunction(
                    named: symbolName,
                    in: cacheImage,
                    text: cacheTextSegment,
                    cache: cache,
                    as: T.self
                ) {
                    return function
                }
            }
            return nil
        }

        let setNeedsUpdate = resolve(_SwiftUIPrivateRuntimeCatalog.hostingViewSetNeedsUpdate, as: VoidHook.self)
        let requestUpdateAfter = resolve(_SwiftUIPrivateRuntimeCatalog.hostingViewRequestUpdateAfter, as: DoubleHook.self)
        let renderForPreferences = resolve(_SwiftUIPrivateRuntimeCatalog.hostingViewRenderForPreferences, as: BoolHook.self)
        let preferencesDidChange = resolve(_SwiftUIPrivateRuntimeCatalog.hostingViewPreferencesDidChange, as: VoidHook.self)
        let didRenderHostingView = resolve(_SwiftUIPrivateRuntimeCatalog.hostingViewDidRender, as: VoidHook.self)
        let didRenderHostingController = resolve(_SwiftUIPrivateRuntimeCatalog.hostingControllerDidRender, as: VoidHook.self)

        let resolutionTable: [(String, Bool)] = [
            (_SwiftUIPrivateRuntimeCatalog.hostingViewSetNeedsUpdate.label, setNeedsUpdate != nil),
            (_SwiftUIPrivateRuntimeCatalog.hostingViewRequestUpdateAfter.label, requestUpdateAfter != nil),
            (_SwiftUIPrivateRuntimeCatalog.hostingViewRenderForPreferences.label, renderForPreferences != nil),
            (_SwiftUIPrivateRuntimeCatalog.hostingViewPreferencesDidChange.label, preferencesDidChange != nil),
            (_SwiftUIPrivateRuntimeCatalog.hostingViewDidRender.label, didRenderHostingView != nil),
            (_SwiftUIPrivateRuntimeCatalog.hostingControllerDidRender.label, didRenderHostingController != nil),
        ]

        return Self(
            setNeedsUpdate: setNeedsUpdate,
            requestUpdateAfter: requestUpdateAfter,
            renderForPreferences: renderForPreferences,
            preferencesDidChange: preferencesDidChange,
            didRenderHostingView: didRenderHostingView,
            didRenderHostingController: didRenderHostingController,
            missingHookLabels: resolutionTable.compactMap { $0.1 ? nil : $0.0 }
        )
    }
}

struct _SwiftUIObjectiveCRenderDriver {
    let setNeedsUpdate: () -> Void
    let requestUpdateAfter: (Double) -> Void
    let renderForPreferences: (Bool) -> Void
    let preferencesDidChange: () -> Void
    let didRenderHostingView: () -> Void
    let didRenderHostingController: () -> Void
}

private enum _SwiftUIPrivateRuntimeCatalog {
    static let textSegmentName = "__TEXT"

    static let hostingViewSetNeedsUpdate = _SwiftUIPrivateHookSpec(
        label: "_UIHostingView.setNeedsUpdate()",
        mangledNames: [
            "_$s7SwiftUI14_UIHostingViewC14setNeedsUpdateyyF"
        ]
    )
    static let hostingViewRequestUpdateAfter = _SwiftUIPrivateHookSpec(
        label: "_UIHostingView.requestUpdate(after:)",
        mangledNames: [
            "_$s7SwiftUI14_UIHostingViewC13requestUpdate5afterySd_tF"
        ]
    )
    static let hostingViewRenderForPreferences = _SwiftUIPrivateHookSpec(
        label: "_UIHostingView.renderForPreferences(updateDisplayList:)",
        mangledNames: [
            "_$s7SwiftUI14_UIHostingViewC20renderForPreferences17updateDisplayListySb_tF"
        ]
    )
    static let hostingViewPreferencesDidChange = _SwiftUIPrivateHookSpec(
        label: "_UIHostingView.preferencesDidChange()",
        mangledNames: [
            "_$s7SwiftUI14_UIHostingViewC20preferencesDidChangeyyF"
        ]
    )
    static let hostingViewDidRender = _SwiftUIPrivateHookSpec(
        label: "_UIHostingView.didRender()",
        mangledNames: [
            "_$s7SwiftUI14_UIHostingViewC9didRenderyyF"
        ]
    )
    static let hostingControllerDidRender = _SwiftUIPrivateHookSpec(
        label: "UIHostingController.didRender()",
        mangledNames: [
            "_$s7SwiftUI19UIHostingControllerC9didRenderyyF"
        ]
    )
}

@unsafe
private enum _SwiftUIPrivateRuntimeUnsafe {
    static func loadedSwiftUIImage() -> MachOImage? {
        MachOImage.images.first(where: { imagePathMatches($0.path) })
    }

    static func cacheImage(in cache: DyldCacheLoaded?) -> MachOImage? {
        cache?.machOImages().first(where: { imagePathMatches($0.path) })
    }

    static func textSegment(in image: MachOImage) -> SegmentCommand64? {
        image.segments64.first(where: { $0.segmentName == _SwiftUIPrivateRuntimeCatalog.textSegmentName })
    }

    static func imagePathMatches(_ path: String?) -> Bool {
        guard let path else { return false }
        return path.contains("/SwiftUI.framework/")
            && path.hasSuffix("SwiftUI")
    }

    static func resolveLoadedImageFunction<T>(
        named symbolName: String,
        in image: MachOImage?,
        text: SegmentCommand64?,
        as type: T.Type
    ) -> T? {
        _ = type

        guard let image, let text else {
            return nil
        }
        guard let symbol = image.symbol(named: symbolName, mangled: true, inSection: 0, isGlobalOnly: false),
              symbol.offset >= 0 else {
            return nil
        }

        let offset = UInt64(symbol.offset)
        guard offset < UInt64(text.virtualMemorySize) else {
            return nil
        }

        let address = UInt64(UInt(bitPattern: image.ptr)) + offset
        guard let pointer = UnsafeRawPointer(bitPattern: UInt(address)) else {
            return nil
        }
        return unsafeBitCast(pointer, to: T.self)
    }

    static func resolveSharedCacheFunction<T>(
        named symbolName: String,
        in image: MachOImage?,
        text: SegmentCommand64?,
        cache: DyldCacheLoaded?,
        as type: T.Type
    ) -> T? {
        _ = type

        guard let image, let text, let cache,
              let localSymbolsInfo = cache.localSymbolsInfo,
              let symbols = localSymbolsInfo.symbols64(in: cache) else {
            return nil
        }

        let dylibOffset = UInt64(text.virtualMemoryAddress) - cache.mainCacheHeader.sharedRegionStart
        guard let entry = localSymbolsInfo.entries(in: cache).first(where: {
            UInt64($0.dylibOffset) == dylibOffset
        }) else {
            return nil
        }

        let textVMAddress = UInt64(text.virtualMemoryAddress)
        let textStart = UInt64(UInt(bitPattern: image.ptr))
        let textRange = textStart ..< (textStart + UInt64(text.virtualMemorySize))

        for symbolIndex in entry.nlistRange {
            let symbol = symbols[symbolIndex]
            guard symbol.name == symbolName, symbol.offset >= 0 else {
                continue
            }

            let unslidAddress = UInt64(symbol.offset)
            guard unslidAddress >= textVMAddress else {
                return nil
            }

            let offsetWithinText = unslidAddress - textVMAddress
            let resolvedAddress = textRange.lowerBound + offsetWithinText
            guard textRange.contains(resolvedAddress),
                  let pointer = UnsafeRawPointer(bitPattern: UInt(resolvedAddress)) else {
                return nil
            }
            return unsafeBitCast(pointer, to: T.self)
        }

        return nil
    }
}

@MainActor
enum _SwiftUIPrivateRuntime {
    private static let resolvedHooks = _SwiftUIResolvedHooks.load()
    private static var didLogMissingHooks = false
#if DEBUG
    static var forceDisableRenderDriver = false
#endif

    static var hooks: _SwiftUIResolvedHooks {
        logMissingHooksIfNeeded()
        return resolvedHooks
    }

    static var canDriveRenderCycle: Bool {
#if DEBUG
        guard !forceDisableRenderDriver else { return false }
#endif
        return hooks.canDriveRenderCycle
    }

    static func renderDriver(
        hostView: AnyObject,
        hostingController: AnyObject
    ) -> _SwiftUIObjectiveCRenderDriver? {
#if DEBUG
        guard !forceDisableRenderDriver else { return nil }
#endif
        guard let setNeedsUpdateSelector = selector(
                in: hostView,
                exactNames: ["setNeedsUpdate"],
                contains: "setNeedsUpdate",
                parameterCount: 0
              ),
              let requestUpdateSelector = selector(
                in: hostView,
                exactNames: ["requestUpdateAfter:"],
                contains: "requestUpdate",
                parameterCount: 1
              ),
              let renderForPreferencesSelector = selector(
                in: hostView,
                exactNames: [
                    "renderForPreferencesWithUpdateDisplayList:",
                    "renderForPreferencesUpdateDisplayList:",
                    "renderForPreferences:"
                ],
                contains: "renderForPreferences",
                parameterCount: 1
              ),
              let preferencesDidChangeSelector = selector(
                in: hostView,
                exactNames: ["preferencesDidChange"],
                contains: "preferencesDidChange",
                parameterCount: 0
              ),
              let didRenderHostingViewSelector = selector(
                in: hostView,
                exactNames: ["didRender"],
                contains: "didRender",
                parameterCount: 0
              ),
              let didRenderHostingControllerSelector = selector(
                in: hostingController,
                exactNames: ["didRender"],
                contains: "didRender",
                parameterCount: 0
              )
        else {
            return nil
        }

        return _SwiftUIObjectiveCRenderDriver(
            setNeedsUpdate: makeVoidInvoker(object: hostView, selector: setNeedsUpdateSelector),
            requestUpdateAfter: makeDoubleInvoker(object: hostView, selector: requestUpdateSelector),
            renderForPreferences: makeBoolInvoker(object: hostView, selector: renderForPreferencesSelector),
            preferencesDidChange: makeVoidInvoker(object: hostView, selector: preferencesDidChangeSelector),
            didRenderHostingView: makeVoidInvoker(object: hostView, selector: didRenderHostingViewSelector),
            didRenderHostingController: makeVoidInvoker(object: hostingController, selector: didRenderHostingControllerSelector)
        )
    }

    static func resolutionStatus(
        hostView: AnyObject,
        hostingController: AnyObject
    ) -> [String: Bool] {
        let objectiveCSelectors = [
            _SwiftUIPrivateRuntimeCatalog.hostingViewSetNeedsUpdate.label: selector(
                in: hostView,
                exactNames: ["setNeedsUpdate"],
                contains: "setNeedsUpdate",
                parameterCount: 0
            ) != nil,
            _SwiftUIPrivateRuntimeCatalog.hostingViewRequestUpdateAfter.label: selector(
                in: hostView,
                exactNames: ["requestUpdateAfter:"],
                contains: "requestUpdate",
                parameterCount: 1
            ) != nil,
            _SwiftUIPrivateRuntimeCatalog.hostingViewRenderForPreferences.label: selector(
                in: hostView,
                exactNames: [
                    "renderForPreferencesWithUpdateDisplayList:",
                    "renderForPreferencesUpdateDisplayList:",
                    "renderForPreferences:"
                ],
                contains: "renderForPreferences",
                parameterCount: 1
            ) != nil,
            _SwiftUIPrivateRuntimeCatalog.hostingViewPreferencesDidChange.label: selector(
                in: hostView,
                exactNames: ["preferencesDidChange"],
                contains: "preferencesDidChange",
                parameterCount: 0
            ) != nil,
            _SwiftUIPrivateRuntimeCatalog.hostingViewDidRender.label: selector(
                in: hostView,
                exactNames: ["didRender"],
                contains: "didRender",
                parameterCount: 0
            ) != nil,
            _SwiftUIPrivateRuntimeCatalog.hostingControllerDidRender.label: selector(
                in: hostingController,
                exactNames: ["didRender"],
                contains: "didRender",
                parameterCount: 0
            ) != nil,
        ]

        let symbolStatus = hooks.resolutionStatus
        return Dictionary(uniqueKeysWithValues: objectiveCSelectors.map { key, value in
            (key, value || (symbolStatus[key] ?? false))
        })
    }

    private static func logMissingHooksIfNeeded() {
        guard !didLogMissingHooks else { return }
        guard !resolvedHooks.missingHookLabels.isEmpty else { return }
        didLogMissingHooks = true
#if DEBUG
        print("DEBUG UIHostingMenu: unresolved SwiftUI private hooks: \(resolvedHooks.missingHookLabels.joined(separator: ", "))")
#endif
    }
}

#if DEBUG
extension _SwiftUIResolvedHooks {
    var resolutionStatus: [String: Bool] {
        [
            _SwiftUIPrivateRuntimeCatalog.hostingViewSetNeedsUpdate.label: setNeedsUpdate != nil,
            _SwiftUIPrivateRuntimeCatalog.hostingViewRequestUpdateAfter.label: requestUpdateAfter != nil,
            _SwiftUIPrivateRuntimeCatalog.hostingViewRenderForPreferences.label: renderForPreferences != nil,
            _SwiftUIPrivateRuntimeCatalog.hostingViewPreferencesDidChange.label: preferencesDidChange != nil,
            _SwiftUIPrivateRuntimeCatalog.hostingViewDidRender.label: didRenderHostingView != nil,
            _SwiftUIPrivateRuntimeCatalog.hostingControllerDidRender.label: didRenderHostingController != nil,
        ]
    }
}
#endif

private extension _SwiftUIPrivateRuntime {
    static func selector(
        in object: AnyObject,
        exactNames: [String],
        contains substring: String,
        parameterCount: Int
    ) -> Selector? {
        for name in exactNames {
            let selector = NSSelectorFromString(name)
            if object.responds(to: selector) {
                return selector
            }
        }

        var currentClass: AnyClass? = object_getClass(object)
        while let cls = currentClass {
            var count: UInt32 = 0
            guard let methods = class_copyMethodList(cls, &count) else {
                currentClass = class_getSuperclass(cls)
                continue
            }
            defer { free(methods) }

            for index in 0..<Int(count) {
                let selector = method_getName(methods[index])
                let name = NSStringFromSelector(selector)
                guard name.contains(substring),
                      name.filter({ $0 == ":" }).count == parameterCount
                else {
                    continue
                }
                return selector
            }

            currentClass = class_getSuperclass(cls)
        }
        return nil
    }

    static func makeVoidInvoker(object: AnyObject, selector: Selector) -> () -> Void {
        typealias Function = @convention(c) (AnyObject, Selector) -> Void
        let method = class_getInstanceMethod(type(of: object), selector)!
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return {
            function(object, selector)
        }
    }

    static func makeBoolInvoker(object: AnyObject, selector: Selector) -> (Bool) -> Void {
        typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Void
        let method = class_getInstanceMethod(type(of: object), selector)!
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return { value in
            function(object, selector, value)
        }
    }

    static func makeDoubleInvoker(object: AnyObject, selector: Selector) -> (Double) -> Void {
        typealias Function = @convention(c) (AnyObject, Selector, Double) -> Void
        let method = class_getInstanceMethod(type(of: object), selector)!
        let implementation = method_getImplementation(method)
        let function = unsafeBitCast(implementation, to: Function.self)
        return { value in
            function(object, selector, value)
        }
    }
}
