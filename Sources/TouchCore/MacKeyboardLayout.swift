// Copyright 2026 Deep Interaction Lab Inc.
// SPDX-License-Identifier: Apache-2.0
#if os(macOS)
import Carbon
import Foundation

/// Resolve the character in the actual layout, never assume a QWERTY physical position.
@MainActor
public enum MacKeyboardLayout {
    public enum LayoutError: LocalizedError {
        case unavailable,unmapped(String)
        public var errorDescription: String? {
            switch self {
            case .unavailable: "Mac keyboard layout is unavailable · shortcut was not sent"
            case .unmapped(let letter): "Could not resolve \(letter.uppercased()) in the Mac keyboard layout · shortcut was not sent"
            }
        }
    }
    public static func keyCode(for letter: String) throws -> UInt16 {
        guard let source=TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { throw LayoutError.unavailable }
        return try keyCode(for:letter,source:source)
    }
    // Internal source injection lets tests exercise both installed US and French layouts.
    static func keyCode(for letter: String,source: TISInputSource) throws -> UInt16 {
        guard let raw=TISGetInputSourceProperty(source,kTISPropertyUnicodeKeyLayoutData) else { throw LayoutError.unavailable }
        let data=unsafeBitCast(raw,to:CFData.self)
        guard let bytes=CFDataGetBytePtr(data) else { throw LayoutError.unavailable }
        let layout=UnsafeRawPointer(bytes).assumingMemoryBound(to:UCKeyboardLayout.self)
        for code in UInt16(0)..<128 {
            var dead: UInt32=0
            var count=0
            var chars=[UniChar](repeating:0,count:8)
            let result=chars.withUnsafeMutableBufferPointer { buffer in
                UCKeyTranslate(layout,code,UInt16(kUCKeyActionDown),0,UInt32(LMGetKbdType()),OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),&dead,8,&count,buffer.baseAddress!)
            }
            if result == noErr,count>0,
               String(utf16CodeUnits:chars,count:Int(count)).lowercased() == letter.lowercased() { return code }
        }
        throw LayoutError.unmapped(letter)
    }
}
#endif
