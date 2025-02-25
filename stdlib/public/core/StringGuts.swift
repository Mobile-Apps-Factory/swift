//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SwiftShims

//
// StringGuts is a parameterization over String's representations. It provides
// functionality and guidance for efficiently working with Strings.
//
@frozen
public // SPI(corelibs-foundation)
struct _StringGuts: @unchecked Sendable {
  @usableFromInline
  internal var _object: _StringObject

  @inlinable @inline(__always)
  internal init(_ object: _StringObject) {
    self._object = object
    _invariantCheck()
  }

  // Empty string
  @inlinable @inline(__always)
  init() {
    self.init(_StringObject(empty: ()))
  }
}

// Raw
extension _StringGuts {
  @inlinable @inline(__always)
  internal var rawBits: _StringObject.RawBitPattern {
    return _object.rawBits
  }
}

// Creation
extension _StringGuts {
  @inlinable @inline(__always)
  internal init(_ smol: _SmallString) {
    self.init(_StringObject(smol))
  }

  @inlinable @inline(__always)
  internal init(_ bufPtr: UnsafeBufferPointer<UInt8>, isASCII: Bool) {
    self.init(_StringObject(immortal: bufPtr, isASCII: isASCII))
  }

  @inline(__always)
  internal init(_ storage: __StringStorage) {
    self.init(_StringObject(storage))
  }

  internal init(_ storage: __SharedStringStorage) {
    self.init(_StringObject(storage))
  }

  internal init(
    cocoa: AnyObject, providesFastUTF8: Bool, isASCII: Bool, length: Int
  ) {
    self.init(_StringObject(
      cocoa: cocoa,
      providesFastUTF8: providesFastUTF8,
      isASCII: isASCII,
      length: length))
  }
}

// Queries
extension _StringGuts {
  // The number of code units
  @inlinable @inline(__always)
  internal var count: Int { return _object.count }

  @inlinable @inline(__always)
  internal var isEmpty: Bool { return count == 0 }

  @inlinable @inline(__always)
  internal var isSmall: Bool { return _object.isSmall }

  @inline(__always)
  internal var isSmallASCII: Bool {
    return _object.isSmall && _object.smallIsASCII
  }

  @inlinable @inline(__always)
  internal var asSmall: _SmallString {
    return _SmallString(_object)
  }

  @inlinable @inline(__always)
  internal var isASCII: Bool  {
    return _object.isASCII
  }

  @inlinable @inline(__always)
  internal var isFastASCII: Bool  {
    return isFastUTF8 && _object.isASCII
  }

  @inline(__always)
  internal var isNFC: Bool { return _object.isNFC }

  @inline(__always)
  internal var isNFCFastUTF8: Bool {
    // TODO(String micro-performance): Consider a dedicated bit for this
    return _object.isNFC && isFastUTF8
  }

  internal var hasNativeStorage: Bool { return _object.hasNativeStorage }

  internal var hasSharedStorage: Bool { return _object.hasSharedStorage }

  // Whether this string has breadcrumbs
  internal var hasBreadcrumbs: Bool {
    return hasSharedStorage
      || (hasNativeStorage && _object.nativeStorage.hasBreadcrumbs)
  }
}

//
extension _StringGuts {
  // Whether we can provide fast access to contiguous UTF-8 code units
  @_transparent
  @inlinable
  internal var isFastUTF8: Bool { return _fastPath(_object.providesFastUTF8) }

  // A String which does not provide fast access to contiguous UTF-8 code units
  @inlinable @inline(__always)
  internal var isForeign: Bool {
     return _slowPath(_object.isForeign)
  }

  @inlinable @inline(__always)
  internal func withFastUTF8<R>(
    _ f: (UnsafeBufferPointer<UInt8>) throws -> R
  ) rethrows -> R {
    _internalInvariant(isFastUTF8)

    if self.isSmall { return try _SmallString(_object).withUTF8(f) }

    defer { _fixLifetime(self) }
    return try f(_object.fastUTF8)
  }

  @inlinable @inline(__always)
  internal func withFastUTF8<R>(
    range: Range<Int>,
    _ f: (UnsafeBufferPointer<UInt8>) throws -> R
  ) rethrows -> R {
    return try self.withFastUTF8 { wholeUTF8 in
      return try f(UnsafeBufferPointer(rebasing: wholeUTF8[range]))
    }
  }

  @inlinable @inline(__always)
  internal func withFastCChar<R>(
    _ f: (UnsafeBufferPointer<CChar>) throws -> R
  ) rethrows -> R {
    return try self.withFastUTF8 { utf8 in
      return try utf8.withMemoryRebound(to: CChar.self, f)
    }
  }
}

// Internal invariants
extension _StringGuts {
  #if !INTERNAL_CHECKS_ENABLED
  @inlinable @inline(__always) internal func _invariantCheck() {}
  #else
  @usableFromInline @inline(never) @_effects(releasenone)
  internal func _invariantCheck() {
    #if arch(i386) || arch(arm) || arch(arm64_32) || arch(wasm32)
    _internalInvariant(MemoryLayout<String>.size == 12, """
    the runtime is depending on this, update Reflection.mm and \
    this if you change it
    """)
    #else
    _internalInvariant(MemoryLayout<String>.size == 16, """
    the runtime is depending on this, update Reflection.mm and \
    this if you change it
    """)
    #endif
  }
  #endif // INTERNAL_CHECKS_ENABLED

  internal func _dump() { _object._dump() }
}

// C String interop
extension _StringGuts {
  @inlinable @inline(__always) // fast-path: already C-string compatible
  internal func withCString<Result>(
    _ body: (UnsafePointer<Int8>) throws -> Result
  ) rethrows -> Result {
    if _slowPath(!_object.isFastZeroTerminated) {
      return try _slowWithCString(body)
    }

    return try self.withFastCChar {
      return try body($0.baseAddress._unsafelyUnwrappedUnchecked)
    }
  }

  @inline(never) // slow-path
  @usableFromInline
  internal func _slowWithCString<Result>(
    _ body: (UnsafePointer<Int8>) throws -> Result
  ) rethrows -> Result {
    _internalInvariant(!_object.isFastZeroTerminated)
    return try String(self).utf8CString.withUnsafeBufferPointer {
      let ptr = $0.baseAddress._unsafelyUnwrappedUnchecked
      return try body(ptr)
    }
  }
}

extension _StringGuts {
  // Copy UTF-8 contents. Returns number written or nil if not enough space.
  // Contents of the buffer are unspecified if nil is returned.
  @inlinable
  internal func copyUTF8(into mbp: UnsafeMutableBufferPointer<UInt8>) -> Int? {
    let ptr = mbp.baseAddress._unsafelyUnwrappedUnchecked
    if _fastPath(self.isFastUTF8) {
      return self.withFastUTF8 { utf8 in
        guard utf8.count <= mbp.count else { return nil }

        let utf8Start = utf8.baseAddress._unsafelyUnwrappedUnchecked
        ptr.initialize(from: utf8Start, count: utf8.count)
        return utf8.count
      }
    }

    return _foreignCopyUTF8(into: mbp)
  }
  @_effects(releasenone)
  @usableFromInline @inline(never) // slow-path
  internal func _foreignCopyUTF8(
    into mbp: UnsafeMutableBufferPointer<UInt8>
  ) -> Int? {
    #if _runtime(_ObjC)
    // Currently, foreign  means NSString
    if let res = _cocoaStringCopyUTF8(_object.cocoaObject,
      into: UnsafeMutableRawBufferPointer(start: mbp.baseAddress,
                                          count: mbp.count)) {
      return res
    }
    
    // If the NSString contains invalid UTF8 (e.g. unpaired surrogates), we
    // can get nil from cocoaStringCopyUTF8 in situations where a character by
    // character loop would get something more useful like repaired contents
    var ptr = mbp.baseAddress._unsafelyUnwrappedUnchecked
    var numWritten = 0
    for cu in String(self).utf8 {
      guard numWritten < mbp.count else { return nil }
      ptr.initialize(to: cu)
      ptr += 1
      numWritten += 1
    }
    
    return numWritten
    #else
    fatalError("No foreign strings on Linux in this version of Swift")
    #endif
  }

  @inline(__always)
  internal var utf8Count: Int {
    if _fastPath(self.isFastUTF8) { return count }
    return String(self).utf8.count
  }
}

// Index
extension _StringGuts {
  @usableFromInline
  internal typealias Index = String.Index

  @inlinable @inline(__always)
  internal var startIndex: String.Index {
    // The start index is always `Character` aligned.
    Index(_encodedOffset: 0)._characterAligned._encodingIndependent
  }

  @inlinable @inline(__always)
  internal var endIndex: String.Index {
    // The end index is always `Character` aligned.
    markEncoding(Index(_encodedOffset: self.count)._characterAligned)
  }
}

// Encoding
extension _StringGuts {
  /// Returns whether this string has a UTF-8 storage representation.
  ///
  /// This always returns a value corresponding to the string's actual encoding.
  @_alwaysEmitIntoClient
  @inline(__always)
  internal var isUTF8: Bool { _object.isUTF8 }

  /// Returns whether this string has a UTF-16 storage representation.
  ///
  /// This always returns a value corresponding to the string's actual encoding.
  @_alwaysEmitIntoClient
  @inline(__always)
  internal var isUTF16: Bool { _object.isUTF16 }

  @_alwaysEmitIntoClient // Swift 5.7
  @inline(__always)
  internal func markEncoding(_ i: String.Index) -> String.Index {
    isUTF8 ? i._knownUTF8 : i._knownUTF16
  }

  /// Returns true if the encoding of the given index isn't known to be in
  /// conflict with this string's encoding.
  ///
  /// If the index was created by code that was built on a stdlib below 5.7,
  /// then this check may incorrectly return true on a mismatching index, but it
  /// is guaranteed to never incorrectly return false. If all loaded binaries
  /// were built in 5.7+, then this method is guaranteed to always return the
  /// correct value.
  @_alwaysEmitIntoClient @inline(__always)
  internal func hasMatchingEncoding(_ i: String.Index) -> Bool {
    i._hasMatchingEncoding(isUTF8: isUTF8)
  }

  /// Return an index whose encoding can be assumed to match that of `self`.
  ///
  /// Detecting an encoding mismatch isn't always possible -- older binaries did
  /// not set the flags that this method relies on. However, false positives
  /// cannot happen: if this method detects a mismatch, then it is guaranteed to
  /// be a real one.
  @_alwaysEmitIntoClient
  @inline(__always)
  internal func ensureMatchingEncoding(_ i: String.Index) -> String.Index {
    if _fastPath(hasMatchingEncoding(i)) { return i }
    return _slowEnsureMatchingEncoding(i)
  }

  @_alwaysEmitIntoClient
  @inline(never)
  @_effects(releasenone)
  internal func _slowEnsureMatchingEncoding(_ i: String.Index) -> String.Index {
    guard isUTF8 else {
      // Attempt to use an UTF-8 index on a UTF-16 string. Strings don't usually
      // get converted to UTF-16 storage, so it seems okay to trap in this case
      // -- the index most likely comes from an unrelated string. (Trapping here
      // may still turn out to affect binary compatibility with broken code in
      // existing binaries running with new stdlibs. If so, we can replace this
      // with the same transcoding hack as in the UTF-16->8 case below.)
      //
      // Note that this trap is not guaranteed to trigger when the process
      // includes client binaries compiled with a previous Swift release.
      // (`i._canBeUTF16` can sometimes return true in that case even if the
      // index actually came from an UTF-8 string.) However, the trap will still
      // often trigger in this case, as long as the index was initialized by
      // code that was compiled with 5.7+.
      //
      // This trap can never trigger on OSes that have stdlibs <= 5.6, because
      // those versions never set the `isKnownUTF16` flag in `_StringObject`.
      _preconditionFailure("Invalid string index")
    }
    // Attempt to use an UTF-16 index on a UTF-8 string.
    //
    // This can happen if `self` was originally verbatim-bridged, and someone
    // mistakenly attempts to keep using an old index after a mutation. This is
    // technically an error, but trapping here would trigger a lot of broken
    // code that previously happened to work "fine" on e.g. ASCII strings.
    // Instead, attempt to convert the offset to UTF-8 code units by transcoding
    // the string. This can be slow, but it often results in a usable index,
    // even if non-ASCII characters are present. (UTF-16 breadcrumbs help reduce
    // the severity of the slowdown.)

    // FIXME: Consider emitting a runtime warning here.
    // FIXME: Consider performing a linked-on-or-after check & trapping if the
    // client executable was built on some particular future Swift release.
    let utf16 = String(self).utf16
    let base = utf16.index(utf16.startIndex, offsetBy: i._encodedOffset)
    if i.transcodedOffset == 0 { return base }
    return base.encoded(offsetBy: i.transcodedOffset)._knownUTF8
  }
}

// Old SPI(corelibs-foundation)
extension _StringGuts {
  @available(*, deprecated)
  public // SPI(corelibs-foundation)
  var _isContiguousASCII: Bool {
    return !isSmall && isFastUTF8 && isASCII
  }

  @available(*, deprecated)
  public // SPI(corelibs-foundation)
  var _isContiguousUTF16: Bool {
    return false
  }

  // FIXME: Remove. Still used by swift-corelibs-foundation
  @available(*, deprecated)
  public var startASCII: UnsafeMutablePointer<UInt8> {
    return UnsafeMutablePointer(mutating: _object.fastUTF8.baseAddress!)
  }

  // FIXME: Remove. Still used by swift-corelibs-foundation
  @available(*, deprecated)
  public var startUTF16: UnsafeMutablePointer<UTF16.CodeUnit> {
    fatalError("Not contiguous UTF-16")
  }
}

@available(*, deprecated)
public // SPI(corelibs-foundation)
func _persistCString(_ p: UnsafePointer<CChar>?) -> [CChar]? {
  guard let s = p else { return nil }
  let bytesToCopy = UTF8._nullCodeUnitOffset(in: s) + 1 // +1 for the terminating NUL
  let result = [CChar](unsafeUninitializedCapacity: bytesToCopy) { buf, initedCount in
    buf.baseAddress!.assign(from: s, count: bytesToCopy)
    initedCount = bytesToCopy
  }
  return result
}

