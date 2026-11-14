// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

import struct Foundation.Data

extension InternalTOMLEncoder.KEC {
	func setupTable() {
		if let parentKey = self.parentKey {
			if self.tomlValue.table?[parentKey.stringValue]?.tomlValue.table == nil {
				self.tomlValue.table?[parentKey.stringValue] = TOMLTable().tomlValue
			}
		}
	}

	func encodeNil(forKey key: Key) throws {}

	func encode(_ value: Bool, forKey key: Key) throws {
		self.setupTable()
		if let parentKey = self.parentKey {
			self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = value
		} else {
			self.tomlValue.table?[key.stringValue] = value
		}
	}

	func encode(_ value: String, forKey key: Key) throws {
		self.setupTable()
		if let parentKey = self.parentKey {
			self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = value
		} else {
			self.tomlValue.table?[key.stringValue] = value
		}
	}

	func encode(_ value: Double, forKey key: Key) throws {
		self.setupTable()
		if let parentKey = self.parentKey {
			self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = value
		} else {
			self.tomlValue.table?[key.stringValue] = value
		}
	}

	func encode(_ value: Float, forKey key: Key) throws {
		self.setupTable()
		if let parentKey = self.parentKey {
			self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = Double(value).tomlValue
		} else {
			self.tomlValue.table?[key.stringValue] = Double(value).tomlValue
		}
	}

	func encode(_ value: Int, forKey key: Key) throws {
		self.setupTable()
		if let parentKey = self.parentKey {
			self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = value
		} else {
			self.tomlValue.table?[key.stringValue] = value
		}
	}

	func encode(_ value: Int8, forKey key: Key) throws {
		self.setupTable()
		if let parentKey = self.parentKey {
			self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = Int(value)
		} else {
			self.tomlValue.table?[key.stringValue] = Int(value)
		}
	}

	func encode(_ value: Int16, forKey key: Key) throws {
		self.setupTable()
		if let parentKey = self.parentKey {
			self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = Int(value)
		} else {
			self.tomlValue.table?[key.stringValue] = Int(value)
		}
	}

	func encode(_ value: Int32, forKey key: Key) throws {
		self.setupTable()
		if let parentKey = self.parentKey {
			self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = Int(value)
		} else {
			self.tomlValue.table?[key.stringValue] = Int(value)
		}
	}

	func encode(_ value: Int64, forKey key: Key) throws {
		self.setupTable()
		if let parentKey = self.parentKey {
			self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = Int(value)
		} else {
			self.tomlValue.table?[key.stringValue] = Int(value)
		}
	}

	func encode(_ value: UInt, forKey key: Key) throws {
		self.setupTable()
		if let parentKey = self.parentKey {
			self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = Int(value)
		} else {
			self.tomlValue.table?[key.stringValue] = Int(value)
		}
	}

	func encode(_ value: UInt8, forKey key: Key) throws {
		self.setupTable()
		if let parentKey = self.parentKey {
			self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = Int(value)
		} else {
			self.tomlValue.table?[key.stringValue] = Int(value)
		}
	}

	func encode(_ value: UInt16, forKey key: Key) throws {
		self.setupTable()
		if let parentKey = self.parentKey {
			self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = Int(value)
		} else {
			self.tomlValue.table?[key.stringValue] = Int(value)
		}
	}

	func encode(_ value: UInt32, forKey key: Key) throws {
		if let parentKey = self.parentKey {
			self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = Int(value)
		} else {
			self.tomlValue.table?[key.stringValue] = Int(value)
		}
	}

	func encode(_ value: UInt64, forKey key: Key) throws {
		self.setupTable()
		if let parentKey = self.parentKey {
			self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = Int(value)
		} else {
			self.tomlValue.table?[key.stringValue] = Int(value)
		}
	}

	func encode<T>(_ value: T, forKey key: Key) throws where T: Encodable {
		if value is Data {
			self.setupTable()
			if let parentKey = self.parentKey {
				self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = self.dataEncoder(value as! Data)
			} else {
				self.tomlValue.table?[key.stringValue] = self.dataEncoder(value as! Data)
			}
		} else if value is TOMLValueConvertible {
			self.setupTable()
			if let parentKey = self.parentKey {
				self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = (value as! TOMLValueConvertible)
			} else {
				self.tomlValue.table?[key.stringValue] = (value as! TOMLValueConvertible)
			}

		} else {
			self.setupTable()
			if let parentKey = self.parentKey {
				let encoder = InternalTOMLEncoder(
					.left(self.tomlValue.table![parentKey.stringValue]!.table!.tomlValue),
					parentKey: key,
					codingPath: self.codingPath + key,
					userInfo: self.userInfo,
					dataEncoder: self.dataEncoder
				)
				try value.encode(to: encoder)
			} else {
				let encoder = InternalTOMLEncoder(
					.left(self.tomlValue),
					parentKey: key,
					codingPath: self.codingPath + key,
					userInfo: self.userInfo,
					dataEncoder: self.dataEncoder
				)
				try value.encode(to: encoder)
			}
		}
	}

	func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey>
		where NestedKey: CodingKey
	{
		if let parentKey = self.parentKey {
			return KeyedEncodingContainer(
				InternalTOMLEncoder.KEC<NestedKey>(
					self.tomlValue.table![parentKey.stringValue]!.table!.tomlValue,
					parentKey: key,
					codingPath: self.codingPath + key,
					userInfo: self.userInfo,
					dataEncoder: self.dataEncoder
				)
			)
		} else {
			return KeyedEncodingContainer(
				InternalTOMLEncoder.KEC<NestedKey>(
					self.tomlValue,
					parentKey: key,
					codingPath: self.codingPath + key,
					userInfo: self.userInfo,
					dataEncoder: self.dataEncoder
				)
			)
		}
	}

	func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
		self.setupTable()
		if let parentKey = self.parentKey {
			self.tomlValue.table?[parentKey.stringValue]?.table?[key.stringValue] = TOMLArray().tomlValue
			return InternalTOMLEncoder.UEC(
				self.tomlValue.table![parentKey.stringValue]!.table![key.stringValue]!.array!,
				codingPath: self.codingPath + key,
				userInfo: self.userInfo,
				dataEncoder: self.dataEncoder
			)
		} else {
			self.tomlValue.table?[key.stringValue] = TOMLArray().tomlValue
			return InternalTOMLEncoder.UEC(
				self.tomlValue.table![key.stringValue]!.array!,
				codingPath: self.codingPath + key,
				userInfo: self.userInfo,
				dataEncoder: self.dataEncoder
			)
		}
	}

	func superEncoder() -> Encoder {
		fatalError()
	}

	func superEncoder(forKey key: Key) -> Encoder {
		fatalError()
	}
}
