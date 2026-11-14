// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

import struct Foundation.Data

/// `TOMLDecoder` decodes TOML documents into Swift `struct`s.
///
/// ### Customizing Decoding
///
/// By default, `Data` is decoded using Base64, but you can use another method by providing a function to
/// ``TOMLDecoder/dataDecoder``:
/// ```swift
/// let toml = "data = [83, 71, 86, 115, 98, 71, 56, 103, 86, 50, 57, 121, 98, 71, 81, 104]"
///
/// var decoder = TOMLDecoder()
///
/// decoder.dataDecoder = {
/// 	let arr = $0.array!.map({ UInt8($0.int!) })
/// 	return Data(base64Encoded: Data(arr))!
/// }
///
/// let myStruct = try decoder.decode(MyStruct.self, from: toml)
/// String(data: myStruct.data, encoding: .utf8) // <== "Hello World!"
/// ```
public struct TOMLDecoder {
	public var userInfo: [CodingUserInfoKey: Any] = [:]

	/// This function will be used to decode `Data` in a TOML document.
	///
	/// The default decoding mechanism is [Base64](https://en.wikipedia.org/wiki/Base64).
	public var dataDecoder: (TOMLValueConvertible) -> Data? = { $0.string != nil ? Data(base64Encoded: $0.string!) : nil }

	/// When this is true, all the keys in the TOML document must be decoded, otherwise ``UnexpectedKeysError`` will be
	/// thrown.
	public var strictDecoding: Bool = false

	public init(
		strictDecoding: Bool = false,
		dataDecoder: @escaping (TOMLValueConvertible)
			-> Data? = { $0.string != nil ? Data(base64Encoded: $0.string!) : nil }
	) {
		self.dataDecoder = dataDecoder
		self.strictDecoding = strictDecoding
	}

	/// Decodes `T` from a TOML string.
	/// - Parameters:
	///   - type: The type you want to convert `tomlString` to.
	///   - tomlString: The `String` containing the TOML document.
	/// - Throws: ``TOMLParseError`` or `DecodingError`. Can throw ``UnexpectedKeysError`` if
	/// ``TOMLDecoder/strictDecoding`` is `true`.
	/// - Returns: The decoded type.
	public func decode<T: Decodable>(_ type: T.Type, from tomlString: String) throws -> T {
		let table = try TOMLTable(string: tomlString)
		return try self.decode(type, from: table)
	}

	/// Decodes `T` from a ``TOMLTable``.
	/// - Parameters:
	///   - type: The type you want to convert `table` to.
	///   - table: The ``TOMLTable`` that you want to convert to `T`.
	/// - Throws: ``TOMLParseError`` or `DecodingError`. Can throw ``UnexpectedKeysError`` if
	/// ``TOMLDecoder/strictDecoding`` is `true`.
	/// - Returns: The decoded type.
	public func decode<T: Decodable>(_ type: T.Type, from table: TOMLTable) throws -> T {
		let notDecodedKeys = InternalTOMLDecoder.NotDecodedKeys()

		let decoder = InternalTOMLDecoder(
			table.tomlValue,
			userInfo: self.userInfo,
			dataDecoder: self.dataDecoder,
			strictDecoding: self.strictDecoding,
			notDecodedKeys: notDecodedKeys
		)

		let value = try T(from: decoder)

		if self.strictDecoding {
			guard notDecodedKeys.keys.isEmpty else {
				throw UnexpectedKeysError(keys: notDecodedKeys.keys)
			}
		}

		return value
	}
}

/// This Error is thrown when ``TOMLDecoder/strictDecoding`` is `true` and you try to decode a `struct` whose
/// `CodingKey`s don't exactly match the keys of the TOML document.
public struct UnexpectedKeysError: Error {
	/// The keys of this `Dictionary` are the un-decoded TOML keys, and the values are the `CodingKey`'s that lead to the
	/// TOML keys.
	public let keys: [String: [CodingKey]]
}
