// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

#if canImport(Darwin)
	import Darwin.C
#elseif canImport(Glibc)
	import Glibc
#elseif canImport(ucrt)
	import ucrt
#else
	#error("Unsupported Platform")
#endif

import CTOML

/// A [table](https://toml.io/en/v1.0.0#table) in a TOML document.
///
/// TOML tables are key-value pairs, similar to a Swift `Dictionary`, but unlike a `Dictionary`, their values can be of
/// any type.
/// They are either the root element in a document, or nested inside the root (or another) table.
///
/// To create a ``TOMLTable`` with values, use one of the below methods:
///
/// * From a Dictionary
///
/// ```swift
/// let table = TOMLTable(["string": "Hello, World!", "int": 345025, "double": 025307.350])
///
/// // Or use `TOMLTable`'s `ExpressibleByDictionaryLiteral` conformance.
/// let table = ["string": "Hello, World!", "int": 345025, "double": 025307.350] as TOMLTable
/// ```
///
/// * From a TOML String
///
/// ```swift
/// let toml = """
/// string = "Hello, World!"
/// int = 523053
/// double = 3250.34
/// """
///
/// do {
///    let table = try TOMLTable(string: toml)
/// } catch let error as TOMLParseError {
///    // TOMLParseError occurs when the TOML document is invalid.
///
///    /// `error.source.begin` contains the line and column where the error started,
///    /// and `error.source.end` contains the line where the error ended.
///     print(error.source.begin)
///     print(error.source.end)
/// }
/// ```
///
/// ### Inserting Values
///
/// To insert values, make sure the value conforms to ``TOMLValueConvertible``, then use the
/// ``TOMLTable/subscript(_:)-76dpr``, or the ``TOMLTable/insert(_:at:)`` method:
/// ```swift
/// let table = TOMLTable()
///
/// table["string"] = "Hello, World!"
/// table.insert(127, at: "int")
/// table["table"] = TOMLTable(["string 1": "Hello, Again!"], inline: true)
/// table["table2"] = TOMLTable(["string 2": "Hello, Again!"], inline: false)
///
/// // Insert an integer using an octal representation.
/// table.insert(TOMLInt(0o755, options: .formatAsOctal), at: "octalInt")
/// ```
///
/// ### Retrieving Values
///
/// #### Iteration
///	```swift
/// let table = TOMLTable(["string": "Hello, World!", "int": 345025, "double": 025307.350])
///
/// for (key, value) in table {
///		print("\(key) => \(value.debugDescription)")
/// }
///
/// // string => "Hello, World!"
/// // int => 345025
/// // double => 25307.35
/// ```
///
/// #### Subscript
///
/// ```swift
/// let table = TOMLTable(
///		[
///			"string": "Hello, World!",
///			"int": 345025,
///			"double": 025307.350,
/// 		"InnerTable": TOMLTable(["date": TOMLDate(year: 2022, month: 1, day: 18)]),
///			"array": TOMLArray([1, 2, "3"])
///		]
///	)
///
///	let integer: Int? = table["int"]?.int
///	let string: String? = table["string"]?.string
///	let double: Double? = table["double"]?.double
///	let date: TOMLDate? = table["innerTable"]?["date"]?.date
///	let arrayInt: Int? = table["array"]?[0].int
/// ```
///
/// ### Conversion
///
/// You can convert a table to TOML, JSON, or YAML using the ``TOMLTable/convert(to:options:)`` function:
///
/// ```swift
/// let table: TOMLTable = ...
///
/// // Convert to TOML.
/// let toml = table.convert()
///
/// // Convert to JSON.
/// let json = table.convert(to: .json)
///
/// // Convert to YAML.
/// let yaml = table.convert(to: .yaml)
/// ```
/// You can customize the encoding using ``FormatOptions``:
///
/// ```swift
/// // Convert to TOML with custom settings.
/// let toml = table.convert(to: .toml, options: [.quoteDateAndTimes, .allowMultilineStrings])
/// let json = table.convert(to: .json, options: .quoteDateAndTimes)
/// ```
///
/// If your table has a ``TOMLInt`` with ``ValueOptions``:
///
/// ```swift
/// let toml = TOMLTable(["int": TOMLInt(0o755, options: .formatAsOctal)])
/// 	.convert(to: .toml)
/// ```
///
/// The resulting TOML:
///
/// ```toml
///	int = 0o755
/// ```
///
public final class TOMLTable:
	Equatable, Sequence, Encodable,
	CustomDebugStringConvertible,
	ExpressibleByDictionaryLiteral,
	TOMLValueConvertible
{
	public var type: TOMLType { .table }
	public var debugDescription: String { self.convert() }
	public var tomlValue: TOMLValue { get { .init(self) } set {} }

	/// An `Array` of the keys in this table.
	public var keys: [String] {
		let pointer = tableGetKeys(self.tablePointer)
		defer { free(UnsafeMutablePointer(mutating: pointer)) }
		var keyArray: [String] = []
		for i in 0..<self.count {
			keyArray.append(String(freeing: pointer[i]))
		}

		return keyArray
	}

	/// An `Array` of the `TOMValue`s in this table.
	public var values: [TOMLValue] {
		let pointer = tableGetValues(self.tablePointer)
		defer { free(UnsafeMutablePointer(mutating: pointer)) }
		var tomlValueArray: [TOMLValue] = []

		for i in 0..<self.count {
			tomlValueArray.append(TOMLValue(tomlValuePointer: pointer[i], owner: self.owner))
		}

		return tomlValueArray
	}

	/// Whether this `TOMLTable` is an [inline table](https://toml.io/en/v1.0.0#inline-table) or not.
	///
	/// Use the `get`ter to check if this table is an inline table, and use the `set`ter to make this an inline table.
	public var inline: Bool {
		get { tableInline(self.tablePointer) }
		set { tableSetInline(self.tablePointer, newValue) }
	}

	/// A pointer to the underlying `toml::table`.
	let tablePointer: OpaquePointer

	/// Keeps the tree that holds `tablePointer` alive.
	let owner: TOMLNodeOwner

	/// The amount of elements in the table.
	public var count: Int { tableSize(self.tablePointer) }

	/// Whether the table is empty or not.
	public var isEmpty: Bool { tableIsEmpty(self.tablePointer) }

	/// Whether every element in the table is of the same type.
	public var isHomogeneous: Bool {
		tableIsHomogeneous(self.tablePointer)
	}

	/// Create a new `TOMLTable`.
	/// - Parameter inline: Whether this table will be an [inline table](https://toml.io/en/v1.0.0#inline-table) or not.
	public init(inline: Bool = false) {
		let table = tableCreate()
		self.tablePointer = table
		self.owner = TOMLNodeOwner(root: table)
		self.inline = inline
	}

	/// Creates a new `TOMLTable` from a dictionary,
	/// - Parameters:
	///   - dictionary: The `Dictionary` that will be used to populate the fields of this table.
	///   - inline: Whether this table will be an [inline table](https://toml.io/en/v1.0.0#inline-table) or not.
	public convenience init(_ dictionary: [String: TOMLValueConvertible], inline: Bool = false) {
		self.init(inline: inline)
		dictionary.forEach({ self[$0] = $1 })
	}

	/// Creates a `TOMLTable` from a `String` containing a TOML document.
	/// - Parameters:
	///   - string: The `String` containing a TOML document.
	/// - Throws: ``TOMLParseError`` if an error occurs during parsing.
	public init(string: String) throws {
		let errorPointer = UnsafeMutablePointer<CTOMLParseError>.allocate(capacity: 1)
		defer { errorPointer.deallocate() }

		guard let table = string.withCString({ tableCreateFromString($0, errorPointer) }) else {
			let error = TOMLParseError(cTOMLParseError: errorPointer.pointee)
			free(UnsafeMutablePointer(mutating: errorPointer.pointee.description))
			throw error
		}

		self.tablePointer = table
		self.owner = TOMLNodeOwner(root: table)
	}

	/// Creates a `TOMLTable` by encoding `value` using ``TOMLEncoder``.
	/// - Parameters:
	///   - string: An `Encodable` struct.
	/// - Throws: ``EncodingError`` if an error occurs during encoding.
	public convenience init<V: Encodable>(_ value: V) throws {
		let table: TOMLTable = try TOMLEncoder().encode(value)
		self.init(tablePointer: table.tablePointer, owner: table.owner)
	}

	public required convenience init(dictionaryLiteral elements: (String, TOMLValueConvertible)...) {
		self.init()
		elements.forEach({ self[$0] = $1 })
	}

	init(tablePointer: OpaquePointer, owner: TOMLNodeOwner) {
		self.tablePointer = tablePointer
		self.owner = owner
	}

	public func encode(to encoder: Encoder) throws {
		var c = encoder.container(keyedBy: TableCodingKey.self)

		for (key, value) in self {
			switch value.type {
				case .bool: try c.encode(value.bool!, forKey: TableCodingKey(stringValue: key))
				case .date: try c.encode(value.date!, forKey: TableCodingKey(stringValue: key))
				case .time: try c.encode(value.time!, forKey: TableCodingKey(stringValue: key))
				case .dateTime: try c.encode(value.dateTime!, forKey: TableCodingKey(stringValue: key))
				case .double: try c.encode(value.double!, forKey: TableCodingKey(stringValue: key))
				case .int: try c.encode(value.int!, forKey: TableCodingKey(stringValue: key))
				case .string: try c.encode(value.string!, forKey: TableCodingKey(stringValue: key))
				case .table: try c.encode(value.table!, forKey: TableCodingKey(stringValue: key))
				case .array: try c.encode(value.array!, forKey: TableCodingKey(stringValue: key))
			}
		}
	}

	/// Removes all the values from the table.
	public func clear() {
		tableClear(self.tablePointer)
	}

	/// Insert a value into this `TOMLTable`, or retrieve a value.
	public subscript(key: String) -> TOMLValueConvertible? {
		get {
			guard let pointer = tableGetNode(self.tablePointer, key) else { return nil }
			return TOMLValue(tomlValuePointer: pointer, owner: self.owner)
		}
		set(value) {
			value?.tomlValue.replaceOrInsertInTable(tablePointer: self.tablePointer, key: key)
		}
	}

	/// Converts this `TOMLTable` to a JSON, YAML, or TOML document.
	/// - Parameter format: The format you want to convert `self` to.
	/// - Returns: The `String` containing the JSON, YAML, or TOML document.
	public func convert(
		to format: ConversionFormat = .toml,
		options: FormatOptions = [
			.allowLiteralStrings,
			.allowMultilineStrings,
			.allowUnicodeStrings,
			.allowBinaryIntegers,
			.allowOctalIntegers,
			.allowHexadecimalIntegers,
			.indentations,
		]
	) -> String {
		switch format {
			case .toml: return String(freeing: tableConvertToTOML(self.tablePointer, options.rawValue))
			case .json: return String(freeing: tableConvertToJSON(self.tablePointer, options.rawValue))
			case .yaml: return String(freeing: tableConvertToYAML(self.tablePointer, options.rawValue))
		}
	}

	// MARK: - Protocol Functions

	public static func == (lhs: TOMLTable, rhs: TOMLTable) -> Bool {
		tableEqual(lhs.tablePointer, rhs.tablePointer)
	}

	func insertIntoTable(tablePointer: OpaquePointer, key: String) {
		tableInsertTable(tablePointer, key, self.tablePointer)
	}

	func insertIntoArray(arrayPointer: OpaquePointer, index: Int) {
		arrayInsertTable(arrayPointer, Int64(index), self.tablePointer)
	}

	struct TableCodingKey: CodingKey {
		var stringValue: String
		var intValue: Int?

		init(intValue: Int) {
			self.intValue = intValue
			self.stringValue = String(intValue)
		}

		init(stringValue: String) {
			self.stringValue = stringValue
		}
	}
}
