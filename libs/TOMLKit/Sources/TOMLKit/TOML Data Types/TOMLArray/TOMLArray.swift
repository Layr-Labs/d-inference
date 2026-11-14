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

/// An [array](https://toml.io/en/v1.0.0#array) in a TOML document.
///
/// TOML arrays are similar to Swift `Array`s. They can be nested inside another array, and their values can be of any
/// type.
///
///
/// To create an empty array, use the ``TOMLArray/init()`` initializer.
///
/// To create a an array with values, use one of the below methods:
///
/// ```swift
/// let array = TOMLArray(
/// 	[
/// 		"Hello, World!",
/// 		"Hello, Again!",
/// 		3294923,
/// 		2350.53,
/// 		TOMLTable(["string": "string 1"])
/// 	]
/// )
///
/// // Or use `TOMLArray`'s `ExpressibleByArrayLiteral` conformance.
/// let array = [
/// 	"Hello, World!",
/// 	"Hello, Again!",
/// 	3294923,
/// 	2350.53,
/// 	TOMLTable(["string": "string 1"])
/// ] as TOMLArray
/// ```
///
/// ### Inserting Values
///
/// To insert values, use the ``TOMLArray/subscript(_:)-6f1f``, the ``TOMLArray/append(_:)`` method, or the
/// ``TOMLArray/insert(_:at:)`` method:
///
/// ```swift
/// let array = TOMLArray()
///
/// array.append("Hello, World")
/// array.insert(TOMLInt(0x123abc, options: .formatAsHexadecimal), at: 1)
/// array[0] = TOMLTable(["double": 02734.23])
/// ```
///
/// ### Retrieving Values
///
/// #### Iteration
///
/// ```swift
/// let array: TOMLArray = [1358, 5.149, ["string": "String", "date": TOMLDate(date: Foundation.Date())!] as TOMLTable]
///
/// for value in array {
///    print(value.debugDescription)
/// }
///
/// // 1358
/// // 5.149
/// // date = 2021-12-21
/// // string = 'String'
/// ```
///
/// ### Subscript
///
/// ```swift
/// let array: TOMLArray = [1358, 5.149, ["string": "String", "date": TOMLDate(date: Foundation.Date())!] as TOMLTable]
///
/// if let int = array[0].int {
///    print(int) // <= 1358
/// }
///
/// if let double = array[1].double {
///    print(double) // <= 5.149
/// }
///
/// if let date = array[2]?["date"]?.date {
///    print(date) <= 2021-12-21
/// }
///
/// if let string = array[2]?["string"]?.string {
///    print(string) // <= String
/// }
/// ```
///
public final class TOMLArray:
	Equatable, Sequence, Encodable,
	ExpressibleByArrayLiteral,
	CustomDebugStringConvertible,
	TOMLValueConvertible
{
	public var type: TOMLType { .array }

	public var startIndex: Int { 0 }

	public var endIndex: Int { self.count }

	public var count: Int { arraySize(self.arrayPointer) }

	/// If this array is empty.
	public var isEmpty: Bool { arrayIsEmpty(self.arrayPointer) }

	public var debugDescription: String {
		String(freeing: arrayConvertToTOML(self.arrayPointer))
	}

	public var tomlValue: TOMLValue { get { .init(self) } set {} }

	/// A pointer to the underlying `toml::array`.
	let arrayPointer: OpaquePointer

	/// Keeps the tree that holds `arrayPointer` alive.
	let owner: TOMLNodeOwner

	init(arrayPointer: OpaquePointer, owner: TOMLNodeOwner) {
		self.arrayPointer = arrayPointer
		self.owner = owner
	}

	/// Create a new `TOMLArray`.
	public required init() {
		let array = arrayCreate()
		self.arrayPointer = array
		self.owner = TOMLNodeOwner(root: array)
	}

	/// Creates a new `TOMLArray` using the contents of a Swift `Array`.
	public convenience init(_ array: [TOMLValueConvertible]) {
		self.init()
		array.forEach(self.append(_:))
	}

	/// Initialize a `TOMLArray` from the elements in `S`.
	public convenience init<S: Sequence>(_ sequence: S) where S.Element: TOMLValueConvertible {
		self.init()
		sequence.forEach(self.append(_:))
	}

	public convenience init(arrayLiteral: TOMLValueConvertible...) {
		self.init(arrayLiteral)
	}

	/// Remove all the elements from this array.
	public func clear() {
		arrayClear(self.arrayPointer)
	}

	func insertIntoTable(tablePointer: OpaquePointer, key: String) {
		tableInsertArray(tablePointer, key, self.arrayPointer)
	}

	func insertIntoArray(arrayPointer: OpaquePointer, index: Int) {
		arrayInsertArray(arrayPointer, Int64(index), self.arrayPointer)
	}

	public static func == (lhs: TOMLArray, rhs: TOMLArray) -> Bool {
		arrayEqual(lhs.arrayPointer, rhs.arrayPointer)
	}

	public func makeIterator() -> TOMLArrayIterator {
		TOMLArrayIterator(array: self)
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.unkeyedContainer()

		for value in self {
			switch value.type {
				case .array: try c.encode(value.array!)
				case .table: try c.encode(value.table!)
				case .string: try c.encode(value.string!)
				case .int: try c.encode(value.int!)
				case .double: try c.encode(value.double!)
				case .bool: try c.encode(value.bool!)
				case .date: try c.encode(value.date!)
				case .time: try c.encode(value.time!)
				case .dateTime: try c.encode(value.dateTime!)
			}
		}
	}
}
