// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

import struct Foundation.Data

enum Either<Left, Right> {
	case left(Left)
	case right(Right)
}

final class InternalTOMLEncoder: Encoder {
	var codingPath: [CodingKey]
	var userInfo: [CodingUserInfoKey: Any]
	let tomlValueOrArray: Either<TOMLValue, (array: TOMLArray, index: Int)>
	let parentKey: CodingKey?
	let dataEncoder: (Data) -> TOMLValueConvertible

	init(
		_ tomlValueOrArray: Either<TOMLValue, (array: TOMLArray, index: Int)>,
		parentKey: CodingKey? = nil,
		codingPath: [CodingKey],
		userInfo: [CodingUserInfoKey: Any],
		dataEncoder: @escaping (Data) -> TOMLValueConvertible
	) {
		self.tomlValueOrArray = tomlValueOrArray
		self.parentKey = parentKey
		self.userInfo = userInfo
		self.codingPath = codingPath
		self.dataEncoder = dataEncoder
	}

	private let triedToEncodeSingleValueOrArrayMessage =
		"You can only pass a key-value object (struct, class, `Dictionary`, etc) to `TOMLEncoder.encode()`."

	func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key: CodingKey {
		switch self.tomlValueOrArray {
			case let .left(value):
				var c: [CodingKey] = []
				if let k = self.parentKey { c.append(k) }
				return KeyedEncodingContainer(
					KEC(
						value,
						parentKey: self.parentKey,
						codingPath: self.codingPath + c,
						userInfo: self.userInfo,
						dataEncoder: self.dataEncoder
					)
				)
			case let .right((array, index)):
				let table = TOMLTable()
				array[index] = table
				return KeyedEncodingContainer(
					KEC(
						array[index].tomlValue,
						parentKey: self.parentKey,
						codingPath: self.codingPath + TOMLCodingKey(index: index),
						userInfo: self.userInfo,
						dataEncoder: self.dataEncoder
					)
				)
		}
	}

	func unkeyedContainer() -> UnkeyedEncodingContainer {
		if let parentKey = parentKey {
			switch self.tomlValueOrArray {
				case let .left(value):
					value.table![parentKey.stringValue] = TOMLArray()
					return UEC(
						value.table![parentKey.stringValue]!.array!,
						codingPath: self.codingPath + parentKey,
						userInfo: self.userInfo,
						dataEncoder: self.dataEncoder
					)
				case let .right((containerArray, index)):
					containerArray[index] = TOMLArray()
					return UEC(
						containerArray[index].array!,
						codingPath: self.codingPath + TOMLCodingKey(index: index),
						userInfo: self.userInfo,
						dataEncoder: self.dataEncoder
					)
			}
		} else {
			fatalError(self.triedToEncodeSingleValueOrArrayMessage)
		}
	}

	func singleValueContainer() -> SingleValueEncodingContainer {
		switch self.tomlValueOrArray {
			case let .left(value):
				guard let parentKey = self.parentKey else { fatalError(self.triedToEncodeSingleValueOrArrayMessage) }
				return SVEC(
					.left(value),
					parentKey: parentKey,
					userInfo: self.userInfo,
					dataEncoder: self.dataEncoder
				)
			case let .right((array, index)):
				return SVEC(
					.right((array: array, index: index)),
					parentKey: nil,
					userInfo: self.userInfo,
					dataEncoder: self.dataEncoder
				)
		}
	}

	final class SVEC: SingleValueEncodingContainer {
		var codingPath: [CodingKey]
		var userInfo: [CodingUserInfoKey: Any]
		let tomlValueOrArray: Either<TOMLValue, (array: TOMLArray, index: Int)>
		let parentKey: CodingKey?
		let dataEncoder: (Data) -> TOMLValueConvertible

		init(
			_ tomlValueOrArray: Either<TOMLValue, (array: TOMLArray, index: Int)>,
			parentKey: CodingKey?,
			userInfo: [CodingUserInfoKey: Any] = [:],
			dataEncoder: @escaping (Data) -> TOMLValueConvertible
		) {
			self.tomlValueOrArray = tomlValueOrArray
			self.parentKey = parentKey
			self.userInfo = userInfo
			self.codingPath = []
			self.dataEncoder = dataEncoder
		}
	}

	final class KEC<Key: CodingKey>: KeyedEncodingContainerProtocol {
		var codingPath: [CodingKey]
		var userInfo: [CodingUserInfoKey: Any]
		let tomlValue: TOMLValue
		let parentKey: CodingKey?
		let dataEncoder: (Data) -> TOMLValueConvertible

		init(
			_ tomlValue: TOMLValue,
			parentKey: CodingKey? = nil,
			codingPath: [CodingKey],
			userInfo: [CodingUserInfoKey: Any] = [:],
			dataEncoder: @escaping (Data) -> TOMLValueConvertible
		) {
			self.tomlValue = tomlValue
			self.parentKey = parentKey
			self.userInfo = userInfo
			self.codingPath = codingPath
			self.dataEncoder = dataEncoder
		}
	}

	struct UEC: UnkeyedEncodingContainer {
		var codingPath: [CodingKey]
		var userInfo: [CodingUserInfoKey: Any] = [:]
		let dataEncoder: (Data) -> TOMLValueConvertible
		var currentIndex: Int = 0
		let tomlArray: TOMLArray

		var count: Int {
			self.tomlArray.count
		}

		init(
			_ tomlArray: TOMLArray,
			codingPath: [CodingKey],
			userInfo: [CodingUserInfoKey: Any],
			dataEncoder: @escaping (Data) -> TOMLValueConvertible
		) {
			self.tomlArray = tomlArray
			self.codingPath = codingPath
			self.userInfo = userInfo
			self.dataEncoder = dataEncoder
		}
	}
}
