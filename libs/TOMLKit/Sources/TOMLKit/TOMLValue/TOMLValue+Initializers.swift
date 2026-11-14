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

public extension TOMLValue {
	/// A value for `tomlValuePointer`, a node of the tree `owner` keeps alive.
	internal init(tomlValuePointer: OpaquePointer, owner: TOMLNodeOwner) {
		self.tomlValuePointer = tomlValuePointer
		self.owner = owner
	}

	/// A value that owns `node`, a root the bridge just allocated.
	internal init(ownedNode node: OpaquePointer) {
		self.init(tomlValuePointer: node, owner: TOMLNodeOwner(root: node))
	}

	init(booleanLiteral value: Bool) {
		self.init(ownedNode: nodeFromBool(value))
	}

	init<I: FixedWidthInteger>(_ value: I) {
		self.init(ownedNode: nodeFromInt(Int64(value)))
	}

	init(integerLiteral value: Int) {
		self.init(ownedNode: nodeFromInt(Int64(value)))
	}

	init(_ value: TOMLInt) {
		self.init(ownedNode: nodeFromInt(Int64(value.value)))
		self.tomlInt = value
	}

	init(floatLiteral value: Double) {
		self.init(ownedNode: nodeFromDouble(value))
	}

	init(stringLiteral value: String) {
		self.init(ownedNode: nodeFromString(value))
	}

	init(_ value: TOMLDate) {
		self.init(ownedNode: nodeFromDate(value.cTOMLDate))
	}

	init(_ value: TOMLTime) {
		self.init(ownedNode: nodeFromTime(value.cTOMLTime))
	}

	init(_ value: TOMLDateTime) {
		self.init(ownedNode: value.withCTOMLDateTime(nodeFromDateTime))
	}

	// A table or an array is not copied: the value refers to its node and keeps its tree alive.
	init(_ value: TOMLTable) {
		self.init(tomlValuePointer: nodeFromTable(value.tablePointer), owner: value.owner)
	}

	init(dictionaryLiteral elements: (String, TOMLValue)...) {
		self.init(TOMLTable(Dictionary(uniqueKeysWithValues: elements)))
	}

	init(_ value: TOMLArray) {
		self.init(tomlValuePointer: nodeFromArray(value.arrayPointer), owner: value.owner)
	}

	init(arrayLiteral elements: TOMLValue...) {
		self.init(TOMLArray(elements))
	}
}
