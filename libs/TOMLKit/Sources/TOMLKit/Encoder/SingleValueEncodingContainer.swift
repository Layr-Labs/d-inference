// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

import struct Foundation.Data

extension InternalTOMLEncoder.SVEC {
	func encodeNil() throws {}

	func encode(_ value: Bool) throws {
		switch self.tomlValueOrArray {
			case let .left(t):
				t.table?[self.parentKey!.stringValue] = value
			case let .right((array, index)):
				array[index] = value
		}
	}

	func encode(_ value: String) throws {
		switch self.tomlValueOrArray {
			case let .left(t):
				t.table?[self.parentKey!.stringValue] = value
			case let .right((array, index)):
				array[index] = value
		}
	}

	func encode(_ value: Double) throws {
		switch self.tomlValueOrArray {
			case let .left(t):
				t.table?[self.parentKey!.stringValue] = value
			case let .right((array, index)):
				array[index] = value
		}
	}

	func encode(_ value: Float) throws {
		switch self.tomlValueOrArray {
			case let .left(t):
				t.table?[self.parentKey!.stringValue] = Double(value).tomlValue
			case let .right((array, index)):
				array[index] = Double(value).tomlValue
		}
	}

	func encode(_ value: Int) throws {
		switch self.tomlValueOrArray {
			case let .left(t):
				t.table?[self.parentKey!.stringValue] = value
			case let .right((array, index)):
				array[index] = value
		}
	}

	func encode(_ value: Int8) throws {
		switch self.tomlValueOrArray {
			case let .left(t):
				t.table?[self.parentKey!.stringValue] = Int(value)
			case let .right((array, index)):
				array[index] = Int(value)
		}
	}

	func encode(_ value: Int16) throws {
		switch self.tomlValueOrArray {
			case let .left(t):
				t.table?[self.parentKey!.stringValue] = Int(value)
			case let .right((array, index)):
				array[index] = Int(value)
		}
	}

	func encode(_ value: Int32) throws {
		switch self.tomlValueOrArray {
			case let .left(t):
				t.table?[self.parentKey!.stringValue] = Int(value)
			case let .right((array, index)):
				array[index] = Int(value)
		}
	}

	func encode(_ value: Int64) throws {
		switch self.tomlValueOrArray {
			case let .left(t):
				t.table?[self.parentKey!.stringValue] = Int(value)
			case let .right((array, index)):
				array[index] = Int(value)
		}
	}

	func encode(_ value: UInt) throws {
		switch self.tomlValueOrArray {
			case let .left(t):
				t.table?[self.parentKey!.stringValue] = Int(value)
			case let .right((array, index)):
				array[index] = Int(value)
		}
	}

	func encode(_ value: UInt8) throws {
		switch self.tomlValueOrArray {
			case let .left(t):
				t.table?[self.parentKey!.stringValue] = Int(value)
			case let .right((array, index)):
				array[index] = Int(value)
		}
	}

	func encode(_ value: UInt16) throws {
		switch self.tomlValueOrArray {
			case let .left(t):
				t.table?[self.parentKey!.stringValue] = Int(value)
			case let .right((array, index)):
				array[index] = Int(value)
		}
	}

	func encode(_ value: UInt32) throws {
		switch self.tomlValueOrArray {
			case let .left(t):
				t.table?[self.parentKey!.stringValue] = Int(value)
			case let .right((array, index)):
				array[index] = Int(value)
		}
	}

	func encode(_ value: UInt64) throws {
		switch self.tomlValueOrArray {
			case let .left(t):
				t.table?[self.parentKey!.stringValue] = Int(value)
			case let .right((array, index)):
				array[index] = Int(value)
		}
	}

	func encode<T>(_ value: T) throws where T: Encodable {
		if value is Data {
			switch self.tomlValueOrArray {
				case let .left(t):
					t.table?[self.parentKey!.stringValue] = self.dataEncoder(value as! Data)
				case let .right((array, index)):
					array[index] = self.dataEncoder(value as! Data)
			}
		} else if value is TOMLValueConvertible {
			switch self.tomlValueOrArray {
				case let .left(t):
					t.table?[self.parentKey!.stringValue] = (value as! TOMLValueConvertible)
				case let .right((array, index)):
					array[index] = (value as! TOMLValueConvertible)
			}
		} else {
			switch self.tomlValueOrArray {
				case let .left(t):
					let encoder = InternalTOMLEncoder(
						.left(t.tomlValue),
						parentKey: self.parentKey,
						codingPath: self.codingPath,
						userInfo: self.userInfo,
						dataEncoder: self.dataEncoder
					)
					try value.encode(to: encoder)
				case let .right((array, index)):
					let encoder = InternalTOMLEncoder(
						.right((array: array, index: index)),
						parentKey: self.parentKey,
						codingPath: self.codingPath + TOMLCodingKey(index: index),
						userInfo: self.userInfo,
						dataEncoder: self.dataEncoder
					)
					try value.encode(to: encoder)
			}
		}
	}
}
