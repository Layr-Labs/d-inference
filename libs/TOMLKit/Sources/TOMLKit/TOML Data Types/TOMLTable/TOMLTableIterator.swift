// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

public struct TOMLTableIterator: IteratorProtocol {
	let table: TOMLTable
	var currentIndex = 0
	var storedKeys: [String] = []

	init(table: TOMLTable) {
		self.table = table
	}

	public mutating func next() -> (String, TOMLValueConvertible)? {
		if self.currentIndex == 0 {
			self.storedKeys = self.table.keys
		}

		guard self.currentIndex <= self.table.count - 1 else {
			self.currentIndex = 0
			self.storedKeys = []
			return nil
		}

		let v = (self.storedKeys[self.currentIndex], self.table[self.storedKeys[self.currentIndex]]!)
		self.currentIndex += 1

		return v
	}
}
