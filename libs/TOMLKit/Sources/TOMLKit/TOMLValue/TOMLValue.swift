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

/// A value in a TOML document.
public struct TOMLValue:
	Equatable,
	ExpressibleByFloatLiteral,
	ExpressibleByStringLiteral,
	ExpressibleByBooleanLiteral,
	ExpressibleByIntegerLiteral,
	ExpressibleByArrayLiteral,
	ExpressibleByDictionaryLiteral,
	CustomDebugStringConvertible,
	TOMLValueConvertible
{
	/// The pointer to the underlying `toml::node`.
	let tomlValuePointer: OpaquePointer

	/// Keeps the tree that holds `tomlValuePointer` alive.
	let owner: TOMLNodeOwner

	var tomlInt: TOMLInt?

	public var type: TOMLType {
		nodeType(self.tomlValuePointer).tomlType
	}

	public var tomlValue: TOMLValue { get { self } set {} }

	public var debugDescription: String {
		if let tomlInt = self.tomlInt {
			return tomlInt.debugDescription
		}
		switch self.type {
			case .table: return self.table?.debugDescription ?? ""
			case .array: return self.array?.debugDescription ?? ""
			case .string: return self.string != nil ? "\"" + self.string! + "\"" : ""
			case .int: return self.int != nil ? String(self.int!) : ""
			case .double: return self.double != nil ? String(self.double!) : ""
			case .bool: return self.bool != nil ? String(self.bool!) : ""
			case .date: return self.date?.debugDescription ?? ""
			case .time: return self.time?.debugDescription ?? ""
			case .dateTime: return self.dateTime?.debugDescription ?? ""
		}
	}

	func copy() -> TOMLValue {
		TOMLValue(ownedNode: copyNode(self.tomlValuePointer))
	}

	public static func == (lhs: TOMLValue, rhs: TOMLValue) -> Bool {
		switch (lhs.type, rhs.type) {
			case (.table, .table): return lhs.table! == rhs.table!
			case (.array, .array): return lhs.array! == rhs.array!
			case (.string, .string): return lhs.string! == rhs.string!
			case (.int, .int): return lhs.int! == rhs.int!
			case (.double, .double): return lhs.double! == rhs.double!
			case (.bool, .bool): return lhs.bool! == rhs.bool!
			case (.date, .date): return lhs.date! == rhs.date!
			case (.time, .time): return lhs.time! == rhs.time!
			case (.dateTime, .dateTime): return lhs.dateTime! == rhs.dateTime!
			default: return false
		}
	}

	/// Insert the TOML value into the table referenced by `tablePointer`.
	/// - Parameters:
	///   - tablePointer: The pointer to the `toml::table` that this value will be inserted in.
	///   - key:
	func insertIntoTable(tablePointer: OpaquePointer, key: String) {
		if let t = self.tomlInt {
			tableInsertInt(tablePointer, key, Int64(t.value), t.options.rawValue)
		} else {
			tableInsertNode(tablePointer, key, self.tomlValuePointer)
		}
	}

	func replaceOrInsertInTable(tablePointer: OpaquePointer, key: String) {
		if let t = self.tomlInt {
			tableReplaceOrInsertInt(tablePointer, key, Int64(t.value), t.options.rawValue)
		} else {
			tableReplaceOrInsertNode(tablePointer, key, self.tomlValuePointer)
		}
	}

	/// Insert the TOML value into the array referenced by `arrayPointer`.
	/// - Parameters:
	///   - tablePointer: The pointer to the `toml::array` that this value will be inserted in.
	///   - index:
	func insertIntoArray(arrayPointer: OpaquePointer, index: Int) {
		if let t = self.tomlInt {
			arrayInsertInt(arrayPointer, Int64(index), Int64(t.value), t.options.rawValue)
		} else {
			arrayInsertNode(arrayPointer, Int64(index), self.tomlValuePointer)
		}
	}

	func replaceInArray(arrayPointer: OpaquePointer, index: Int) {
		switch self.type {
			case .table:
				arrayReplaceTable(arrayPointer, Int64(index), self.table!.tablePointer)
			case .array:
				arrayReplaceArray(arrayPointer, Int64(index), self.array!.arrayPointer)
			case .string:
				self.string!.withCString({ arrayReplaceString(arrayPointer, Int64(index), $0) })
			case .int:
				if let t = self.tomlInt {
					arrayReplaceInt(arrayPointer, Int64(index), Int64(t.value), t.options.rawValue)
				} else {
					arrayReplaceInt(arrayPointer, Int64(index), Int64(self.int!), ValueOptions.none.rawValue)
				}
			case .double:
				arrayReplaceDouble(arrayPointer, Int64(index), self.double!)
			case .bool:
				arrayReplaceBool(arrayPointer, Int64(index), self.bool!)
			case .date:
				arrayReplaceDate(arrayPointer, Int64(index), self.date!.cTOMLDate)
			case .time:
				arrayReplaceTime(arrayPointer, Int64(index), self.time!.cTOMLTime)
			case .dateTime:
				self.dateTime!.withCTOMLDateTime { arrayReplaceDateTime(arrayPointer, Int64(index), $0) }
		}
	}
}
