// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

import struct Foundation.Data

final class InternalTOMLDecoder: Decoder {
	var codingPath: [CodingKey] = []
	var userInfo: [CodingUserInfoKey: Any] = [:]
	var dataDecoder: (TOMLValueConvertible) -> Data?
	var strictDecoding: Bool = false
	var notDecodedKeys: NotDecodedKeys

	let tomlValue: TOMLValue
	init(
		_ tomlValue: TOMLValue,
		userInfo: [CodingUserInfoKey: Any] = [:],
		codingPath: [CodingKey] = [],
		dataDecoder: @escaping (TOMLValueConvertible) -> Data?,
		strictDecoding: Bool,
		notDecodedKeys: NotDecodedKeys
	) {
		self.tomlValue = tomlValue
		self.userInfo = userInfo
		self.codingPath = codingPath
		self.dataDecoder = dataDecoder
		self.strictDecoding = strictDecoding
		self.notDecodedKeys = notDecodedKeys
	}

	func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> where Key: CodingKey {
		guard let table = self.tomlValue.table else {
			throw DecodingError.typeMismatch(
				TOMLTable.self,
				DecodingError
					.Context(
						codingPath: self.codingPath,
						debugDescription: "Expected a table, but found a \(self.tomlValue.type.description) instead."
					)
			)
		}

		return KeyedDecodingContainer<Key>(
			KDC(
				table: table,
				codingPath: self.codingPath,
				userInfo: self.userInfo,
				dataDecoder: self.dataDecoder,
				strictDecoding: self.strictDecoding,
				notDecodedKeys: self.notDecodedKeys
			)
		)
	}

	func unkeyedContainer() throws -> UnkeyedDecodingContainer {
		guard let array = self.tomlValue.array else {
			throw DecodingError.typeMismatch(
				TOMLArray.self,
				DecodingError.Context(
					codingPath: self.codingPath,
					debugDescription: "Expected a TOMLArray but found a \(self.tomlValue.type.description) instead."
				)
			)
		}
		return UDC(
			array,
			codingPath: self.codingPath,
			userInfo: self.userInfo,
			dataDecoder: self.dataDecoder,
			strictDecoding: self.strictDecoding,
			notDecodedKeys: self.notDecodedKeys
		)
	}

	func singleValueContainer() throws -> SingleValueDecodingContainer {
		SVDC(
			self.tomlValue,
			codingPath: self.codingPath,
			dataDecoder: self.dataDecoder,
			strictDecoding: self.strictDecoding,
			notDecodedKeys: self.notDecodedKeys
		)
	}

	final class SVDC: SingleValueDecodingContainer {
		var codingPath: [CodingKey] = []
		var userInfo: [CodingUserInfoKey: Any] = [:]
		var dataDecoder: (TOMLValueConvertible) -> Data?
		let tomlValue: TOMLValue
		var strictDecoding: Bool
		var notDecodedKeys: NotDecodedKeys

		init(
			_ tomlValue: TOMLValue,
			codingPath: [CodingKey],
			userInfo: [CodingUserInfoKey: Any] = [:],
			dataDecoder: @escaping (TOMLValueConvertible) -> Data?,
			strictDecoding: Bool,
			notDecodedKeys: NotDecodedKeys
		) {
			self.tomlValue = tomlValue
			self.userInfo = userInfo
			self.codingPath = codingPath
			self.dataDecoder = dataDecoder
			self.strictDecoding = strictDecoding
			self.notDecodedKeys = notDecodedKeys
		}
	}

	final class KDC<Key: CodingKey>: KeyedDecodingContainerProtocol {
		var codingPath: [CodingKey] = []
		var userInfo: [CodingUserInfoKey: Any] = [:]
		var dataDecoder: (TOMLValueConvertible) -> Data?
		var allKeys: [Key] = []
		let table: TOMLTable
		let strictDecoding: Bool
		var notDecodedKeys: NotDecodedKeys

		var decodedKeys: [String] = []

		init(
			table: TOMLTable,
			codingPath: [CodingKey],
			userInfo: [CodingUserInfoKey: Any],
			dataDecoder: @escaping (TOMLValueConvertible) -> Data?,
			strictDecoding: Bool,
			notDecodedKeys: NotDecodedKeys
		) {
			self.table = table
			self.userInfo = userInfo
			self.codingPath = codingPath
			self.dataDecoder = dataDecoder
			self.allKeys = table.keys.compactMap(Self.Key.init(stringValue:))
			self.strictDecoding = strictDecoding
			self.notDecodedKeys = notDecodedKeys
		}

		deinit {
			guard self.strictDecoding else { return }

			let sortedDecodedKeys = self.decodedKeys.sorted()
			let sortedTableKeys = self.table.keys.sorted()

			let diff = sortedDecodedKeys.difference(from: sortedTableKeys)

			if !diff.isEmpty {
				for diffElement in diff {
					switch diffElement {
						case .remove(offset: _, element: let e, associatedWith: _):
							self.notDecodedKeys.keys[e] = self.codingPath + (Key(stringValue: e) ?? TOMLCodingKey(stringValue: e)!)
						default: break
					}
				}
			}
		}
	}

	final class UDC: UnkeyedDecodingContainer {
		var codingPath: [CodingKey]
		var userInfo: [CodingUserInfoKey: Any] = [:]
		var dataDecoder: (TOMLValueConvertible) -> Data?
		var strictDecoding: Bool
		var notDecodedKeys: NotDecodedKeys

		var count: Int? { self.tomlArray.count }

		var isAtEnd: Bool {
			guard let count = self.count else { return true }
			return self.currentIndex >= count
		}

		var currentIndex: Int = 0

		let tomlArray: TOMLArray

		init(
			_ tomlArray: TOMLArray,
			codingPath: [CodingKey],
			userInfo: [CodingUserInfoKey: Any],
			dataDecoder: @escaping (TOMLValueConvertible) -> Data?,
			strictDecoding: Bool,
			notDecodedKeys: NotDecodedKeys
		) {
			self.tomlArray = tomlArray
			self.codingPath = codingPath
			self.userInfo = userInfo
			self.dataDecoder = dataDecoder
			self.strictDecoding = strictDecoding
			self.notDecodedKeys = notDecodedKeys
		}
	}

	final class NotDecodedKeys {
		var keys: [String: [CodingKey]] = [:]
	}
}
