// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

public struct TOMLArrayIterator: IteratorProtocol {
	let array: TOMLArray
	var currentIndex = 0

	public mutating func next() -> TOMLValueConvertible? {
		guard self.currentIndex <= self.array.endIndex - 1 else { return nil }
		let element = self.array[self.currentIndex]
		self.currentIndex += 1
		return element
	}
}
