// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

import struct Foundation.Data

extension InternalTOMLEncoder.UEC {
	mutating func encodeNil() throws {}

	mutating func encode(_ value: Bool) throws {
		self.tomlArray[self.currentIndex] = value
		self.currentIndex += 1
	}

	mutating func encode(_ value: String) throws {
		self.tomlArray[self.currentIndex] = value
		self.currentIndex += 1
	}

	mutating func encode(_ value: Double) throws {
		self.tomlArray[self.currentIndex] = value
		self.currentIndex += 1
	}

	mutating func encode(_ value: Float) throws {
		self.tomlArray[self.currentIndex] = Double(value)
		self.currentIndex += 1
	}

	mutating func encode(_ value: Int) throws {
		self.tomlArray[self.currentIndex] = value
		self.currentIndex += 1
	}

	mutating func encode(_ value: Int8) throws {
		self.tomlArray[self.currentIndex] = Int(value)
		self.currentIndex += 1
	}

	mutating func encode(_ value: Int16) throws {
		self.tomlArray[self.currentIndex] = Int(value)
		self.currentIndex += 1
	}

	mutating func encode(_ value: Int32) throws {
		self.tomlArray[self.currentIndex] = Int(value)
		self.currentIndex += 1
	}

	mutating func encode(_ value: Int64) throws {
		self.tomlArray[self.currentIndex] = Int(value)
		self.currentIndex += 1
	}

	mutating func encode(_ value: UInt) throws {
		self.tomlArray[self.currentIndex] = Int(value)
		self.currentIndex += 1
	}

	mutating func encode(_ value: UInt8) throws {
		self.tomlArray[self.currentIndex] = Int(value)
		self.currentIndex += 1
	}

	mutating func encode(_ value: UInt16) throws {
		self.tomlArray[self.currentIndex] = Int(value)
		self.currentIndex += 1
	}

	mutating func encode(_ value: UInt32) throws {
		self.tomlArray[self.currentIndex] = Int(value)
		self.currentIndex += 1
	}

	mutating func encode(_ value: UInt64) throws {
		self.tomlArray[self.currentIndex] = Int(value)
		self.currentIndex += 1
	}

	mutating func encode<T>(_ value: T) throws where T: Encodable {
		switch value {
			case is Data: self.tomlArray[self.currentIndex] = self.dataEncoder(value as! Data)
			case is TOMLValueConvertible: self.tomlArray[self.currentIndex] = (value as! TOMLValueConvertible)
			default:
				let encoder = InternalTOMLEncoder(
					.right((array: self.tomlArray, index: self.currentIndex)),
					parentKey: nil,
					codingPath: self.codingPath + TOMLCodingKey(index: self.currentIndex),
					userInfo: self.userInfo,
					dataEncoder: self.dataEncoder
				)

				try value.encode(to: encoder)
		}

		self.currentIndex += 1
	}

	mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey>
		where NestedKey: CodingKey
	{
		let table = TOMLTable()
		self.tomlArray[self.currentIndex] = table

		return KeyedEncodingContainer(
			InternalTOMLEncoder.KEC<NestedKey>(
				table.tomlValue,
				codingPath: self.codingPath + TOMLCodingKey(index: self.currentIndex),
				userInfo: self.userInfo,
				dataEncoder: self.dataEncoder
			)
		)
	}

	mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
		self.tomlArray[self.currentIndex] = TOMLArray()
		return InternalTOMLEncoder.UEC(
			self.tomlArray[self.currentIndex].array!,
			codingPath: self.codingPath + TOMLCodingKey(index: self.currentIndex),
			userInfo: self.userInfo,
			dataEncoder: self.dataEncoder
		)
	}

	mutating func superEncoder() -> Encoder {
		fatalError()
	}
}
