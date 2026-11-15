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

public extension TOMLTable {
	func contains(key: String) -> Bool {
		tableContains(self.tablePointer, key)
	}

	func contains(element: TOMLValueConvertible) -> Bool {
		let e = element.tomlValue

		for v in self.values {
			if e == v { return true }
		}

		return false
	}

	func insert(_ value: TOMLValueConvertible, at key: String) {
		value.tomlValue.insertIntoTable(tablePointer: self.tablePointer, key: key)
	}

	/// Remove the element at `key` from this table.
	///
	/// - Returns: `nil` if there was no value at `key`, or the value that was deleted at `key`.
	@discardableResult func remove(at key: String) -> TOMLValueConvertible? {
		if let v = self[key]?.tomlValue.tomlValuePointer {
			let element = TOMLValue(ownedNode: copyNode(v))
			tableRemoveElement(self.tablePointer, key)
			return element
		} else {
			return nil
		}
	}

	func makeIterator() -> TOMLTableIterator {
		TOMLTableIterator(table: self)
	}
}
