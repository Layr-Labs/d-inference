// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

import struct Foundation.Data

extension InternalTOMLDecoder.KDC {
	private func decodeInt(key: Key) throws -> Int {
		guard let i = self.table[key.stringValue]?.int else {
			throw DecodingError.keyNotFound(
				key,
				DecodingError
					.Context(
						codingPath: self.codingPath + key,
						debugDescription: "A \"Int\" does not exist at \"\(key.stringValue)\" in the TOML table."
					)
			)
		}

		self.decodedKeys.append(key.stringValue)

		return i
	}

	func contains(_ key: Key) -> Bool {
		self.table[key.stringValue] != nil
	}

	func decodeNil(forKey key: Key) throws -> Bool {
		self.decodedKeys.append(key.stringValue)
		return self.table[key.stringValue] == nil
	}

	func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
		guard let b = self.table[key.stringValue]?.bool else {
			throw DecodingError.keyNotFound(
				key,
				DecodingError
					.Context(
						codingPath: self.codingPath + key,
						debugDescription: "A \"\(type)\" does not exist at \"\(key.stringValue)\" in the TOML table."
					)
			)
		}

		self.decodedKeys.append(key.stringValue)

		return b
	}

	func decode(_ type: String.Type, forKey key: Key) throws -> String {
		guard let s = self.table[key.stringValue]?.string else {
			throw DecodingError.keyNotFound(
				key,
				DecodingError
					.Context(
						codingPath: self.codingPath + key,
						debugDescription: "A \"\(type)\" does not exist at \"\(key.stringValue)\" in the TOML table."
					)
			)
		}

		self.decodedKeys.append(key.stringValue)

		return s
	}

	func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
		guard let d = self.table[key.stringValue]?.double else {
			throw DecodingError.keyNotFound(
				key,
				DecodingError
					.Context(
						codingPath: self.codingPath + key,
						debugDescription: "A \"\(type)\" does not exist at \"\(key.stringValue)\" in the TOML table."
					)
			)
		}

		self.decodedKeys.append(key.stringValue)

		return d
	}

	func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
		guard let d = self.table[key.stringValue]?.double else {
			throw DecodingError.keyNotFound(
				key,
				DecodingError
					.Context(
						codingPath: self.codingPath + key,
						debugDescription: "A \"\(type)\" does not exist at \"\(key.stringValue)\" in the TOML table."
					)
			)
		}

		self.decodedKeys.append(key.stringValue)

		return Float(d)
	}

	func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
		try self.decodeInt(key: key)
	}

	func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
		try Int8(self.decodeInt(key: key))
	}

	func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
		try Int16(self.decodeInt(key: key))
	}

	func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
		try Int32(self.decodeInt(key: key))
	}

	func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
		try Int64(self.decodeInt(key: key))
	}

	func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
		try UInt(self.decodeInt(key: key))
	}

	func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
		try UInt8(self.decodeInt(key: key))
	}

	func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
		try UInt16(self.decodeInt(key: key))
	}

	func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
		try UInt32(self.decodeInt(key: key))
	}

	func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
		try UInt64(self.decodeInt(key: key))
	}

	func decode<T>(_ type: T.Type, forKey key: Key) throws -> T where T: Decodable {
		// Check if `type` is a TOMLTime, TOMLDate, or TOMLDateTime.
		switch self.table[key.stringValue]?.type {
			case .time:
				guard let value = self.table[key.stringValue]?.time as? T else {
					throw DecodingError.typeMismatch(
						TOMLTime.self,
						DecodingError
							.Context(
								codingPath: self.codingPath + key,
								debugDescription: "Expected to decode a \(self.table[key.stringValue]?.type.description ?? "") type at \(key.stringValue) but found a \(T.self) instead."
							)
					)
				}

				self.decodedKeys.append(key.stringValue)

				return value
			case .date:
				guard let value = self.table[key.stringValue]?.date as? T else {
					throw DecodingError.typeMismatch(
						TOMLDate.self,
						DecodingError
							.Context(
								codingPath: self.codingPath + key,
								debugDescription: "Expected to decode a \(self.table[key.stringValue]?.type.description ?? "") type at \(key.stringValue) but found a \(T.self) instead."
							)
					)
				}

				self.decodedKeys.append(key.stringValue)

				return value
			case .dateTime:
				guard let value = self.table[key.stringValue]?.dateTime as? T else {
					throw DecodingError.typeMismatch(
						TOMLDateTime.self,
						DecodingError
							.Context(
								codingPath: self.codingPath + key,
								debugDescription: "Expected to decode a \(self.table[key.stringValue]?.type.description ?? "") type at \(key.stringValue) but found a \(T.self) instead."
							)
					)
				}

				self.decodedKeys.append(key.stringValue)

				return value
			case .none:
				throw DecodingError.keyNotFound(
					key,
					DecodingError
						.Context(
							codingPath: self.codingPath + key,
							debugDescription: "The key \"\(key.stringValue)\" was not found in the TOML table."
						)
				)
			default:
				if type is Data.Type, let value = self.table[key.stringValue] {
					guard let data = self.dataDecoder(value) else {
						throw DecodingError.dataCorrupted(DecodingError.Context(
							codingPath: self.codingPath + key,
							debugDescription: "Unable to decode Data from \"\(value)\". Key: \(key.stringValue)"
						))
					}

					self.decodedKeys.append(key.stringValue)

					return data as! T
				} else {
					guard let value = self.table[key.stringValue]?.tomlValue else {
						throw DecodingError.keyNotFound(
							key,
							DecodingError
								.Context(
									codingPath: self.codingPath + key,
									debugDescription: "The key \"\(key.stringValue)\" was not found in the TOML table."
								)
						)
					}

					let decoder = InternalTOMLDecoder(
						value,
						userInfo: self.userInfo,
						codingPath: self.codingPath + key,
						dataDecoder: self.dataDecoder,
						strictDecoding: self.strictDecoding,
						notDecodedKeys: self.notDecodedKeys
					)

					self.decodedKeys.append(key.stringValue)

					return try T(from: decoder)
				}
		}
	}

	func nestedContainer<NestedKey>(
		keyedBy type: NestedKey.Type,
		forKey key: Key
	) throws -> KeyedDecodingContainer<NestedKey> where NestedKey: CodingKey {
		guard let table = self.table[key.stringValue]?.table else {
			throw DecodingError.typeMismatch(
				TOMLTable.self,
				DecodingError
					.Context(
						codingPath: self.codingPath + key,
						debugDescription: "Expected a TOMLTable but found a \(self.table[key.stringValue]?.type.description ?? "No type") instead."
					)
			)
		}

		self.decodedKeys.append(key.stringValue)

		return KeyedDecodingContainer<NestedKey>(InternalTOMLDecoder.KDC<NestedKey>(
			table: table,
			codingPath: self.codingPath + key,
			userInfo: self.userInfo,
			dataDecoder: self.dataDecoder,
			strictDecoding: self.strictDecoding,
			notDecodedKeys: self.notDecodedKeys
		))
	}

	func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
		guard let array = self.table[key.stringValue]?.array else {
			throw DecodingError.keyNotFound(
				key,
				DecodingError
					.Context(
						codingPath: self.codingPath + key,
						debugDescription: "An array does not exist at \"\(key.stringValue)\" in the TOML table."
					)
			)
		}

		self.decodedKeys.append(key.stringValue)

		return InternalTOMLDecoder.UDC(
			array,
			codingPath: self.codingPath + key,
			userInfo: self.userInfo,
			dataDecoder: self.dataDecoder,
			strictDecoding: self.strictDecoding,
			notDecodedKeys: self.notDecodedKeys
		)
	}

	func superDecoder() throws -> Decoder {
		fatalError()
	}

	func superDecoder(forKey key: Key) throws -> Decoder {
		fatalError()
	}
}
