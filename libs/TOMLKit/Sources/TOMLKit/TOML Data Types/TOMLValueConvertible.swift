// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

#if canImport(Darwin)
	import Darwin.C
#elseif canImport(Glibc)
	import Glibc
#elseif canImport(ucrt)
	import ucrt
#else
	#error("Unsupported Platform")
#endif

import CTOML
import struct Foundation.Data

/// A type that can be converted into a value in a TOML document.
///
/// You should not conform your types to this protocol. Instead, interact with this protocol through the types that
/// conform to it:
///
/// ```swift
/// myTOMLTable["string"]! // <- subscript returns `TOMLValueConvertible`
/// myTOMLArray[0] // <- subscript returns `TOMLValueConvertible`
///
/// myTOMLTable["int"] = 1 // as TOMLValueConvertible
/// myTOMLArray.append(true /* as TOMLValueConvertible */)
/// ```
///
/// The properties in this protocol are used to determine the TOML type of a ``TOMLValueConvertible`` conformant type,
/// or to convert a generic ``TOMLValueConvertible`` to a concrete type:
///
/// ```swift
///	let array: TOMLArray? = myTOMLArray[0].array
///	let int: Int? = myTOMLTable["int"]?.int
///	let table: TOMLTable? = myTOMLArray[0]?[6]?["table"]?.table // `TOMLValueConvertible` provides subscripts for
/// nesting
///
///	switch myTOMLTable["table"]?.type {
///		...
///	}
/// ```
///
public protocol TOMLValueConvertible: CustomDebugStringConvertible {
	/// What kind of TOML value this is.
	var type: TOMLType { get }

	/// The `TOMLValue` for this value, used for inserting this value into a `TOMLArray` or a `TOMLTable`.
	var tomlValue: TOMLValue { get set }
}

public extension TOMLValueConvertible {
	/// Converts this `TOMLValueConvertible` to a `Bool`. If the conversion fails, this will return `nil`.
	var bool: Bool? {
		let value = self.tomlValue
		guard value.type == .bool else { return nil }
		return value.readCopy(nodeAsBool) { $0 }
	}

	/// Converts this `TOMLValueConvertible` to an `Int`. If the conversion fails, this will return `nil`.
	var int: Int? {
		let value = self.tomlValue
		guard value.type == .int else { return nil }
		return value.readCopy(nodeAsInt) { Int($0) }
	}

	/// Converts this `TOMLValueConvertible` to a `Double`. If the conversion fails, this will return `nil`.
	var double: Double? {
		let value = self.tomlValue
		guard value.type == .double else { return nil }
		return value.readCopy(nodeAsDouble) { $0 }
	}

	/// Converts this `TOMLValueConvertible` to a `String`. If the conversion fails, this will return `nil`.
	var string: String? {
		let value = self.tomlValue
		guard value.type == .string else { return nil }
		return withExtendedLifetime(value) { nodeAsString(value.tomlValuePointer).map(String.init(freeing:)) }
	}

	/// Converts this `TOMLValueConvertible` to a `TOMLDate`. If the conversion fails, this will return `nil`.
	var date: TOMLDate? {
		let value = self.tomlValue
		guard value.type == .date else { return nil }
		return value.readCopy(nodeAsDate, TOMLDate.init(cTOMLDate:))
	}

	/// Converts this `TOMLValueConvertible` to a `TOMLTime`. If the conversion fails, this will return `nil`.
	var time: TOMLTime? {
		let value = self.tomlValue
		guard value.type == .time else { return nil }
		return value.readCopy(nodeAsTime, TOMLTime.init(cTOMLTime:))
	}

	/// Converts this `TOMLValueConvertible` to a `TOMLDateTime`. If the conversion fails, this will return `nil`.
	var dateTime: TOMLDateTime? {
		let value = self.tomlValue
		guard value.type == .dateTime else { return nil }
		return withExtendedLifetime(value) {
			guard let pointer = nodeAsDateTime(value.tomlValuePointer) else { return nil }
			defer { dateTimeFree(pointer) }
			return TOMLDateTime(cTOMLDateTime: pointer.pointee)
		}
	}

	/// Converts this `TOMLValueConvertible` to a `TOMLTable`. If the conversion fails, this will return `nil`.
	var table: TOMLTable? {
		let value = self.tomlValue
		guard value.type == .table else { return nil }
		return withExtendedLifetime(value) {
			nodeAsTable(value.tomlValuePointer).map { TOMLTable(tablePointer: $0, owner: value.owner) }
		}
	}

	/// Converts this `TOMLValueConvertible` to a `TOMLArray`. If the conversion fails, this will return `nil`.
	var array: TOMLArray? {
		let value = self.tomlValue
		guard value.type == .array else { return nil }
		return withExtendedLifetime(value) {
			nodeAsArray(value.tomlValuePointer).map { TOMLArray(arrayPointer: $0, owner: value.owner) }
		}
	}

	/// Converts this `TOMLValueConvertible` to a `TOMLArray`, then returns the `TOMLValue` at `index`, If the conversion
	/// fails, this will return `nil`.
	subscript(index: Int) -> TOMLValue? {
		get {
			guard self.type == .array else { return nil }
			return self.array?[index].tomlValue
		}
		set {
			guard self.type == .array, let n = newValue else { return }
			self.array?[index] = n
		}
	}

	/// Converts this `TOMLValueConvertible` to a `TOMLTable`, then returns the `TOMLValue` at `key`, If the conversion
	/// fails, this will return `nil`.
	subscript(key: String) -> TOMLValue? {
		get {
			guard self.type == .table else { return nil }
			return self.table?[key]?.tomlValue
		}
		set {
			guard self.type == .table else { return }
			self.table?[key] = newValue
		}
	}
}

extension Bool: TOMLValueConvertible {
	public var debugDescription: String { self.description }
	public var type: TOMLType { .bool }
	public var tomlValue: TOMLValue { get { .init(booleanLiteral: self) } set {} }
}

extension Double: TOMLValueConvertible {
	public var type: TOMLType { .double }
	public var tomlValue: TOMLValue { get { .init(floatLiteral: self) } set {} }
}

extension String: TOMLValueConvertible {
	public var type: TOMLType { .string }
	public var debugDescription: String { self }
	public var tomlValue: TOMLValue { get { .init(stringLiteral: self) } set {} }
}

extension Dictionary: TOMLValueConvertible where Self.Value: TOMLValueConvertible, Self.Key == String {
	public var type: TOMLType { .table }
	public var tomlValue: TOMLValue { get { .init(.init(self)) } set {} }
}

extension Array: TOMLValueConvertible where Self.Element: TOMLValueConvertible {
	public var type: TOMLType { .array }
	public var tomlValue: TOMLValue { get { .init(.init(self)) } set {} }
}

extension Data: TOMLValueConvertible {
	public var debugDescription: String { self.description }
	public var type: TOMLType { .string }
	public var tomlValue: TOMLValue { get { .init(stringLiteral: self.base64EncodedString()) } set {} }
}
