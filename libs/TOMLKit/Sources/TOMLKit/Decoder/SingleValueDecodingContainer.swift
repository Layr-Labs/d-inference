// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

import struct Foundation.Data

extension InternalTOMLDecoder.SVDC {
	func decodeNil() -> Bool {
		false
	}

	func decode(_ type: Bool.Type) throws -> Bool {
		guard let b = self.tomlValue.bool else {
			throw DecodingError.typeMismatch(
				Bool.self,
				DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Cannot decode \"\(type)\" from \(self.tomlValue)"
				)
			)
		}

		return b
	}

	func decode(_ type: String.Type) throws -> String {
		guard let s = self.tomlValue.string else {
			throw DecodingError.typeMismatch(
				String.self,
				DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Cannot decode \"\(type)\" from \(self.tomlValue)"
				)
			)
		}

		return s
	}

	func decode(_ type: Double.Type) throws -> Double {
		guard let d = self.tomlValue.double else {
			throw DecodingError.typeMismatch(
				Double.self,
				DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Cannot decode \"\(type)\" from \(self.tomlValue)"
				)
			)
		}

		return d
	}

	func decode(_ type: Float.Type) throws -> Float {
		guard let d = self.tomlValue.double else {
			throw DecodingError.typeMismatch(
				Float.self,
				DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Cannot decode \"\(type)\" from \(self.tomlValue)"
				)
			)
		}

		return Float(d)
	}

	func decode(_ type: Int.Type) throws -> Int {
		guard let i = self.tomlValue.int else {
			throw DecodingError.typeMismatch(
				Int.self,
				DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Cannot decode \"\(type)\" from \(self.tomlValue)"
				)
			)
		}

		return i
	}

	func decode(_ type: Int8.Type) throws -> Int8 {
		guard let i = self.tomlValue.int else {
			throw DecodingError.typeMismatch(
				type,
				DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Cannot decode \"\(type)\" from \(self.tomlValue)"
				)
			)
		}

		return type.init(i)
	}

	func decode(_ type: Int16.Type) throws -> Int16 {
		guard let i = self.tomlValue.int else {
			throw DecodingError.typeMismatch(
				type,
				DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Cannot decode \"\(type)\" from \(self.tomlValue)"
				)
			)
		}

		return type.init(i)
	}

	func decode(_ type: Int32.Type) throws -> Int32 {
		guard let i = self.tomlValue.int else {
			throw DecodingError.typeMismatch(
				type,
				DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Cannot decode \"\(type)\" from \(self.tomlValue)"
				)
			)
		}

		return type.init(i)
	}

	func decode(_ type: Int64.Type) throws -> Int64 {
		guard let i = self.tomlValue.int else {
			throw DecodingError.typeMismatch(
				type,
				DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Cannot decode \"\(type)\" from \(self.tomlValue)"
				)
			)
		}

		return type.init(i)
	}

	func decode(_ type: UInt.Type) throws -> UInt {
		guard let i = self.tomlValue.int else {
			throw DecodingError.typeMismatch(
				type,
				DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Cannot decode \"\(type)\" from \(self.tomlValue)"
				)
			)
		}

		return type.init(i)
	}

	func decode(_ type: UInt8.Type) throws -> UInt8 {
		guard let i = self.self.tomlValue.int else {
			throw DecodingError.typeMismatch(
				type,
				DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Cannot decode \"\(type)\" from \(self.tomlValue)"
				)
			)
		}

		return type.init(i)
	}

	func decode(_ type: UInt16.Type) throws -> UInt16 {
		guard let i = self.tomlValue.int else {
			throw DecodingError.typeMismatch(
				type,
				DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Cannot decode \"\(type)\" from \(self.tomlValue)"
				)
			)
		}

		return type.init(i)
	}

	func decode(_ type: UInt32.Type) throws -> UInt32 {
		guard let i = self.tomlValue.int else {
			throw DecodingError.typeMismatch(
				type,
				DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Cannot decode \"\(type)\" from \(self.tomlValue)"
				)
			)
		}

		return type.init(i)
	}

	func decode(_ type: UInt64.Type) throws -> UInt64 {
		guard let i = self.tomlValue.int else {
			throw DecodingError.typeMismatch(
				type,
				DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Cannot decode \"\(type)\" from \(self.tomlValue)"
				)
			)
		}

		return type.init(i)
	}

	func decode<T>(_ type: T.Type) throws -> T where T: Decodable {
		let decoder = InternalTOMLDecoder(
			self.tomlValue,
			codingPath: self.codingPath,
			dataDecoder: self.dataDecoder,
			strictDecoding: self.strictDecoding,
			notDecodedKeys: self.notDecodedKeys
		)

		if type is Data.Type {
			if let data = self.dataDecoder(self.tomlValue) {
				return data as! T
			} else {
				throw DecodingError.dataCorrupted(DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Unable to decode Data from: \"\(self.tomlValue.debugDescription)\"."
				))
			}
		} else {
			return try T(from: decoder)
		}
	}
}
