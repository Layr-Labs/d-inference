// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

import CTOML

extension TOMLArray:
	Collection,
	RandomAccessCollection,
	BidirectionalCollection,
	RangeReplaceableCollection,
	MutableCollection
{
	public typealias Index = Int
	public typealias Element = TOMLValueConvertible

	public var indices: Range<Index> { 0..<self.endIndex }

	private func checkIndex(_ index: Index) {
		precondition(index <= self.endIndex - 1, "TOMLArray index out of range")
	}

	private func isEmptyPrecondition() {
		precondition(!self.isEmpty, "Cannot remove elements from a empty TOMLArray")
	}

	private func checkPastEndIndex(_ index: Index) {
		precondition(index < self.endIndex, "Cannot advance beyond self.endIndex")
	}

	public func append(_ newElement: Element) {
		newElement.tomlValue.insertIntoArray(arrayPointer: self.arrayPointer, index: self.endIndex)
	}

	public func insert(_ newElement: Element, at i: Index) {
		newElement.tomlValue.insertIntoArray(arrayPointer: self.arrayPointer, index: i)
	}

	public func removeFirst() -> TOMLValueConvertible {
		self.isEmptyPrecondition()

		return self.remove(at: self.startIndex)
	}

	@discardableResult
	public func remove(at i: Index) -> Element {
		self.isEmptyPrecondition()
		self.checkIndex(i)
		let element = self[i].tomlValue.copy()
		arrayRemoveElement(self.arrayPointer, Int64(i))
		return element
	}

	public func removeSubrange(_ bounds: Range<Int>) {
		bounds.reversed().forEach({ self.checkIndex($0)
			self.remove(at: $0) })
	}

	public func replaceSubrange<C>(_ subrange: Range<Int>, with newElements: C) where C: Collection,
		TOMLValueConvertible == C.Element
	{
		self.checkIndex(subrange[subrange.startIndex])
		self.checkIndex(subrange[subrange.endIndex - 1])

		let before = Array(self[0..<subrange[subrange.startIndex]])
		let after = Array(self[(subrange[subrange.endIndex - 1] + 1)...])
		let res = before + newElements + after

		res.indices.forEach({ self[$0] = res[$0] })
	}

	public func index(after i: Int) -> Int {
		self.checkPastEndIndex(i)
		return i + 1
	}

	public subscript(index: Index) -> Element {
		get {
			self.checkIndex(index)
			let pointer = arrayGetNode(self.arrayPointer, Int64(index))
			return TOMLValue(tomlValuePointer: pointer, owner: self.owner)
		}
		set(value) {
			value.tomlValue.replaceInArray(arrayPointer: self.arrayPointer, index: index)
		}
	}
}
