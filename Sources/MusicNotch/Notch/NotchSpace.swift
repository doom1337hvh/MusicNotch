import AppKit

/// A private window-server Space that sits above every desktop. Windows in it stay put
/// while desktops slide past, instead of being drawn into a desktop and moving with it.
/// Used with "Hide while swiping", where the notch is hidden for the swipe and then
/// appears in place without riding in on the settling desktop.
///
/// Like `SpaceObserver`, this uses SkyLight, the private framework behind Mission Control.
/// If a future macOS removes these functions, windows just stay on the normal desktops.
@MainActor
final class NotchSpace {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Void
    private typealias WindowsAndSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func function<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(skyLight, name).map { unsafeBitCast($0, to: type) }
    }

    private let connection: Int32
    private let identifier: UInt64?
    private let addWindows = function("SLSAddWindowsToSpaces", as: WindowsAndSpaces.self)
    private let removeWindows = function("SLSRemoveWindowsFromSpaces", as: WindowsAndSpaces.self)

    init() {
        guard let mainConnectionID = Self.function("SLSMainConnectionID", as: MainConnectionID.self),
              let create = Self.function("SLSSpaceCreate", as: SpaceCreate.self),
              let setLevel = Self.function("SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
              let show = Self.function("SLSShowSpaces", as: ShowSpaces.self)
        else {
            connection = 0
            identifier = nil
            return
        }
        connection = mainConnectionID()
        // The flag has to be 1; other values make Finder draw desktop icons into the Space.
        let space = create(connection, 1, nil)
        setLevel(connection, space, Int32.max)
        show(connection, [NSNumber(value: space)] as CFArray)
        identifier = space
    }

    func add(_ window: NSWindow) {
        guard let identifier, let addWindows, window.windowNumber > 0 else { return }
        addWindows(connection, [NSNumber(value: window.windowNumber)] as CFArray,
                   [NSNumber(value: identifier)] as CFArray)
    }

    func remove(_ window: NSWindow) {
        guard let identifier, let removeWindows, window.windowNumber > 0 else { return }
        removeWindows(connection, [NSNumber(value: window.windowNumber)] as CFArray,
                      [NSNumber(value: identifier)] as CFArray)
    }
}
