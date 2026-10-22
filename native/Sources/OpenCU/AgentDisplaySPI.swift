import AppKit
import ObjectiveC

/// Original runtime bridge, not imported private headers. Every used selector's
/// ABI is checked before a display is allocated. No class lookup creates a display.
/// Undocumented CoreGraphics remains an explicit, experimental OS boundary.
enum AgentDisplaySPI {
    private static func method(_ cls: AnyClass, _ name: String, result: [String], args: [String]) throws -> IMP {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, selector),
              method_getNumberOfArguments(method) == args.count + 2 else { throw unavailable(name) }
        func encoding(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
            guard let pointer else { return "" }
            defer { free(pointer) }
            return String(cString: pointer)
        }
        guard result.contains(encoding(method_copyReturnType(method))) else { throw unavailable(name) }
        for (index, type) in args.enumerated() {
            guard encoding(method_copyArgumentType(method, UInt32(index + 2))) == type else { throw unavailable(name) }
        }
        return method_getImplementation(method)
    }
    private static func unavailable(_ name: String) -> OpenCUError {
        OpenCUError("AGENT_DISPLAY_SPI_UNAVAILABLE", "Unsupported virtual-display class/selector ABI: \(name). No fallback is used.")
    }
    private static func type(_ name: String) throws -> AnyClass {
        guard let cls = NSClassFromString(name) else { throw unavailable(name) }
        return cls
    }
    private static func allocate(_ cls: AnyClass) throws -> UnsafeMutableRawPointer {
        guard let meta = object_getClass(cls) else { throw unavailable("alloc") }
        let imp = try method(meta, "alloc", result: ["@"], args: [])
        typealias Alloc = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
        guard let pointer = unsafeBitCast(imp, to: Alloc.self)(cls, NSSelectorFromString("alloc")) else { throw unavailable("alloc") }
        return pointer
    }
    private static func make(_ cls: AnyClass) throws -> AnyObject {
        let imp = try method(cls, "init", result: ["@"], args: [])
        typealias Init = @convention(c) (UnsafeMutableRawPointer, Selector) -> Unmanaged<AnyObject>?
        guard let object = unsafeBitCast(imp, to: Init.self)(try allocate(cls), NSSelectorFromString("init")) else { throw unavailable("init") }
        return object.takeRetainedValue()
    }
    private static func setObject(_ object: AnyObject, _ name: String, _ value: AnyObject) throws {
        let imp = try method(object_getClass(object)!, name, result: ["v"], args: ["@"])
        typealias Set = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        unsafeBitCast(imp, to: Set.self)(object, NSSelectorFromString(name), value)
    }
    private static func setUInt(_ object: AnyObject, _ name: String, _ value: UInt32) throws {
        let imp = try method(object_getClass(object)!, name, result: ["v"], args: ["I"])
        typealias Set = @convention(c) (AnyObject, Selector, UInt32) -> Void
        unsafeBitCast(imp, to: Set.self)(object, NSSelectorFromString(name), value)
    }

    static func create(scale: Int, size: CGSize) throws -> (object: AnyObject, id: UInt32) {
        let width = UInt32(size.width), height = UInt32(size.height)
        let descriptorClass: AnyClass = try type("CGVirtualDisplayDescriptor")
        let settingsClass: AnyClass = try type("CGVirtualDisplaySettings")
        let modeClass: AnyClass = try type("CGVirtualDisplayMode")
        let displayClass: AnyClass = try type("CGVirtualDisplay")
        for cls in [descriptorClass, settingsClass] { _ = try method(cls, "init", result: ["@"], args: []) }
        for name in ["setName:", "setQueue:"] { _ = try method(descriptorClass, name, result: ["v"], args: ["@"]) }
        for name in ["setMaxPixelsWide:", "setMaxPixelsHigh:", "setVendorID:", "setProductID:", "setSerialNum:", "setSerialNumber:"] {
            _ = try method(descriptorClass, name, result: ["v"], args: ["I"])
        }
        let sizeIMP = try method(descriptorClass, "setSizeInMillimeters:", result: ["v"], args: ["{CGSize=dd}"])
        let primaries: [(String, CGPoint)] = [("setRedPrimary:", CGPoint(x: 0.64, y: 0.33)),
            ("setGreenPrimary:", CGPoint(x: 0.30, y: 0.60)), ("setBluePrimary:", CGPoint(x: 0.15, y: 0.06)),
            ("setWhitePoint:", CGPoint(x: 0.3127, y: 0.3290))]
        for (name, _) in primaries { _ = try method(descriptorClass, name, result: ["v"], args: ["{CGPoint=dd}"]) }
        _ = try method(settingsClass, "setHiDPI:", result: ["v"], args: ["I"])
        _ = try method(settingsClass, "setModes:", result: ["v"], args: ["@"])
        // Chromium's binary-derived declarations use unsigned int here;
        // DeskPad's handwritten NSUInteger declaration is not the ABI contract.
        let modeIMP = try method(modeClass, "initWithWidth:height:refreshRate:", result: ["@"], args: ["I", "I", "d"])
        let displayIMP = try method(displayClass, "initWithDescriptor:", result: ["@"], args: ["@"])
        let applyIMP = try method(displayClass, "applySettings:", result: ["B", "c"], args: ["@"])
        let idIMP = try method(displayClass, "displayID", result: ["I"], args: [])

        let descriptor = try make(descriptorClass)
        try setObject(descriptor, "setName:", PresenceStrings().text("OpenCU Agent Display") as NSString)
        try setObject(descriptor, "setQueue:", DispatchQueue.global(qos: .userInitiated) as AnyObject)
        try setUInt(descriptor, "setMaxPixelsWide:", width * UInt32(scale))
        try setUInt(descriptor, "setMaxPixelsHigh:", height * UInt32(scale))
        try setUInt(descriptor, "setVendorID:", 0x4f43)
        try setUInt(descriptor, "setProductID:", 0x4147)
        // A fresh identity avoids restoring a saved arrangement from a prior run.
        let serial = UInt32.random(in: 1...UInt32.max)
        try setUInt(descriptor, "setSerialNum:", serial)
        try setUInt(descriptor, "setSerialNumber:", serial)
        typealias SetPoint = @convention(c) (AnyObject, Selector, CGPoint) -> Void
        for (name, point) in primaries {
            let imp = try method(descriptorClass, name, result: ["v"], args: ["{CGPoint=dd}"])
            unsafeBitCast(imp, to: SetPoint.self)(descriptor, NSSelectorFromString(name), point)
        }
        typealias SetSize = @convention(c) (AnyObject, Selector, CGSize) -> Void
        unsafeBitCast(sizeIMP, to: SetSize.self)(descriptor, NSSelectorFromString("setSizeInMillimeters:"), CGSize(width: 460, height: 460 * size.height / size.width))
        typealias InitMode = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
        guard let modeResult = unsafeBitCast(modeIMP, to: InitMode.self)(try allocate(modeClass),
            NSSelectorFromString("initWithWidth:height:refreshRate:"), width, height, 60) else {
            throw unavailable("mode initialization")
        }
        let mode = modeResult.takeRetainedValue()
        let settings = try make(settingsClass)
        try setUInt(settings, "setHiDPI:", scale == 2 ? 1 : 0)
        try setObject(settings, "setModes:", [mode] as NSArray)
        typealias InitDisplay = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject) -> Unmanaged<AnyObject>?
        guard let displayResult = unsafeBitCast(displayIMP, to: InitDisplay.self)(try allocate(displayClass),
            NSSelectorFromString("initWithDescriptor:"), descriptor) else { throw unavailable("display initialization") }
        let display = displayResult.takeRetainedValue()
        typealias Apply = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        guard unsafeBitCast(applyIMP, to: Apply.self)(display, NSSelectorFromString("applySettings:"), settings) else {
            throw OpenCUError("AGENT_DISPLAY_CREATE_FAILED", "CoreGraphics refused the virtual display mode.")
        }
        typealias GetID = @convention(c) (AnyObject, Selector) -> UInt32
        let id = unsafeBitCast(idIMP, to: GetID.self)(display, NSSelectorFromString("displayID"))
        guard id != 0 else { throw unavailable("displayID returned zero") }
        return (display, id)
    }
}
