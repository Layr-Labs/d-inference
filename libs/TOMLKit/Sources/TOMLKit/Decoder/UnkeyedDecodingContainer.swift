// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

import struct Foundation.Data

extension InternalTOMLDecoder.UDC {
	func decodeNil() throws -> Bool {
		// There is no `nil` in TOML.
		false
	}

	func decodeInt(type: Any.Type) throws -> Int {
		guard let i = self.tomlArray[self.currentIndex].int else {
			throw DecodingError.typeMismatch(
				type,
				DecodingError
					.Context(
						codingPath: self.codingPath + TOMLCodingKey(index: self.currentIndex),
						debugDescription: "Unable to retrieve a \"\(type)\" from the TOML array at index \(self.currentIndex), found a \(self.tomlArray[self.currentIndex].type.description) instead."
					)
			)
		}

		self.currentIndex += 1

		return i
	}

	func decode(_ type: Bool.Type) throws -> Bool {
		guard let b = self.tomlArray[self.currentIndex].bool else {
			throw DecodingError.typeMismatch(
				type,
				DecodingError
					.Context(
						codingPath: self.codingPath + TOMLCodingKey(index: self.currentIndex),
						debugDescription: "Unable to retrieve \"\(type)\" from the TOML array at index \(self.currentIndex), found a \(self.tomlArray[self.currentIndex].type.description) instead."
					)
			)
		}

		self.currentIndex += 1

		return b
	}

	func decode(_ type: String.Type) throws -> String {
		guard let s = self.tomlArray[self.currentIndex].string else {
			throw DecodingError.typeMismatch(
				type,
				DecodingError
					.Context(
						codingPath: self.codingPath + TOMLCodingKey(index: self.currentIndex),
						debugDescription: "Unable to retrieve \"\(type)\" from the TOML array at index \(self.currentIndex), found a \(self.tomlArray[self.currentIndex].type.description) instead."
					)
			)
		}

		self.currentIndex += 1

		return s
	}

	func decode(_ type: Double.Type) throws -> Double {
		guard let d = self.tomlArray[self.currentIndex].double else {
			throw DecodingError.typeMismatch(
				type,
				DecodingError
					.Context(
						codingPath: self.codingPath + TOMLCodingKey(index: self.currentIndex),
						debugDescription: "Unable to retrieve \"\(type)\" from the TOML array at index \(self.currentIndex), found a \(self.tomlArray[self.currentIndex].type.description) instead."
					)
			)
		}

		self.currentIndex += 1

		return d
	}

	func decode(_ type: Float.Type) throws -> Float {
		guard let d = self.tomlArray[self.currentIndex].double else {
			throw DecodingError.typeMismatch(
				type,
				DecodingError
					.Context(
						codingPath: self.codingPath + TOMLCodingKey(index: self.currentIndex),
						debugDescription: "Unable to retrieve \"\(type)\" from the TOML array at index \(self.currentIndex), found a \(self.tomlArray[self.currentIndex].type.description) instead."
					)
			)
		}

		self.currentIndex += 1

		return Float(d)
	}

	func decode(_ type: Int.Type) throws -> Int {
		try self.decodeInt(type: type)
	}

	func decode(_ type: Int8.Type) throws -> Int8 {
		try Int8(self.decodeInt(type: type))
	}

	func decode(_ type: Int16.Type) throws -> Int16 {
		try Int16(self.decodeInt(type: type))
	}

	func decode(_ type: Int32.Type) throws -> Int32 {
		try Int32(self.decodeInt(type: type))
	}

	func decode(_ type: Int64.Type) throws -> Int64 {
		try Int64(self.decodeInt(type: type))
	}

	func decode(_ type: UInt.Type) throws -> UInt {
		try UInt(self.decodeInt(type: type))
	}

	func decode(_ type: UInt8.Type) throws -> UInt8 {
		try UInt8(self.decodeInt(type: type))
	}

	func decode(_ type: UInt16.Type) throws -> UInt16 {
		try UInt16(self.decodeInt(type: type))
	}

	func decode(_ type: UInt32.Type) throws -> UInt32 {
		try UInt32(self.decodeInt(type: type))
	}

	func decode(_ type: UInt64.Type) throws -> UInt64 {
		try UInt64(self.decodeInt(type: type))
	}

	func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
		if type is Data.Type {
			guard let v = self.tomlArray[self.currentIndex] else {
				throw DecodingError.typeMismatch(
					type,
					DecodingError
						.Context(
							codingPath: self.codingPath + TOMLCodingKey(index: self.currentIndex),
							debugDescription: "Unable to retrieve \"\(type)\" from the TOML array at index \(self.currentIndex), found a \(self.tomlArray[self.currentIndex].type.description) instead."
						)
				)
			}

			guard let data = self.dataDecoder(v) else {
				throw DecodingError.dataCorrupted(DecodingError.Context(
					codingPath: self.codingPath + TOMLCodingKey(index: self.currentIndex),
					debugDescription: "Unable to decode Data from \"\(v.debugDescription)\", at index \(self.currentIndex)."
				))
			}

			self.currentIndex += 1
			return data as! T
		} else {
			let decoder = InternalTOMLDecoder(
				self.tomlArray[self.currentIndex].tomlValue,
				userInfo: self.userInfo,
				codingPath: self.codingPath + TOMLCodingKey(index: self.currentIndex),
				dataDecoder: self.dataDecoder,
				strictDecoding: self.strictDecoding,
				notDecodedKeys: self.notDecodedKeys
			)
			self.currentIndex += 1
			return try T(from: decoder)
		}
	}

	func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey>
		where NestedKey: CodingKey
	{
		guard let table = self.tomlArray[self.currentIndex].table else {
			throw DecodingError.typeMismatch(
				TOMLTable.self,
				DecodingError
					.Context(
						codingPath: self.codingPath,
						debugDescription: "Expected a table, but found a \(self.tomlArray[self.currentIndex].type.description) instead"
					)
			)
		}

		return KeyedDecodingContainer<NestedKey>(
			InternalTOMLDecoder.KDC(
				table: table,
				codingPath: self.codingPath + TOMLCodingKey(index: self.currentIndex),
				userInfo: self.userInfo,
				dataDecoder: self.dataDecoder,
				strictDecoding: self.strictDecoding,
				notDecodedKeys: self.notDecodedKeys
			)
		)
	}

	func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
		guard let nestedArray = self.tomlArray[self.currentIndex].array else {
			throw DecodingError.typeMismatch(
				TOMLArray.self,
				DecodingError
					.Context(
						codingPath: self.codingPath + TOMLCodingKey(index: self.currentIndex),
						debugDescription: "Unable to retrieve an array from the TOML array at index \(self.currentIndex), found a \(self.tomlArray[self.currentIndex].type.description) instead."
					)
			)
		}

		return InternalTOMLDecoder.UDC(
			nestedArray,
			codingPath: self.codingPath + TOMLCodingKey(index: self.currentIndex),
			userInfo: self.userInfo,
			dataDecoder: self.dataDecoder,
			strictDecoding: self.strictDecoding,
			notDecodedKeys: self.notDecodedKeys
		)
	}

	func superDecoder() throws -> Decoder {
		fatalError()
	}
}
