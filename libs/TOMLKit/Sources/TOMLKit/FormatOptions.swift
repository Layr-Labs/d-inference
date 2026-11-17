// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

/// The format to convert a `TOMLTable` to.
public enum ConversionFormat {
	/// The [TOML](https://toml.io) format.
	case toml

	/// The [JSON](https://www.json.org/) format.
	case json

	/// The [YAML](https://yaml.org) format.
	case yaml
}

/// Formatting options that are used when converting a ``TOMLTable`` to a JSON, YAML, or TOML document.
public struct FormatOptions: OptionSet {
	public let rawValue: UInt64

	public init(rawValue: UInt64) {
		self.rawValue = rawValue
	}

	/// Dates and times will be emitted as quoted strings.
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/namespacetoml.html#af1a6761a2f4d80b1a541ba819d9c8e0fa6e569050aafc6eca4c0c5dfab35fd25a).
	public static let quoteDateAndTimes = Self(rawValue: 1 << 0)

	/// Infinities and NaNs will be emitted as quoted strings.
	public static let quoteInfinitesAndNaNs = Self(rawValue: 1 << 1)

	/// Strings will be emitted as single-quoted literal strings where possible.
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/namespacetoml.html#af1a6761a2f4d80b1a541ba819d9c8e0fa328473763ff1ab919ce0b01d66ad3bf6).
	public static let allowLiteralStrings = Self(rawValue: 1 << 2)

	/// Strings containing newlines will be emitted as triple-quoted 'multi-line' strings where possible.
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/namespacetoml.html#af1a6761a2f4d80b1a541ba819d9c8e0fad9467c39215be4189dc8395a830f9051).
	public static let allowMultilineStrings = Self(rawValue: 1 << 3)

	/// Allow real tab characters in string literals (as opposed to the escaped form `\t`).
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/namespacetoml.html#a2102aa80bc57783d96180f36e1f64f6aa85cd74c0ce79c211961b6db05587778c).
	public static let allowRealTabsInStrings = Self(rawValue: 1 << 4)

	/// Allow non-ASCII characters in strings (as opposed to their escaped form, e.g. `\u00DA`).
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/namespacetoml.html#a2102aa80bc57783d96180f36e1f64f6aab8d4fc7b15531737d6d22536c5f3881c).
	public static let allowUnicodeStrings = Self(rawValue: 1 << 5)

	/// Allow integers with ``ValueOptions/formatAsBinary`` to be emitted as binary.
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/namespacetoml.html#a2102aa80bc57783d96180f36e1f64f6aae8dbe11e331b30941899ce81fd2fee41).
	public static let allowBinaryIntegers = Self(rawValue: 1 << 6)

	/// Allow integers with ``ValueOptions/formatAsOctal`` to be emitted as octal.
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/namespacetoml.html#a2102aa80bc57783d96180f36e1f64f6aa3d184bcd6e8f69ebc29b148945f23d4e).
	public static let allowOctalIntegers = Self(rawValue: 1 << 7)

	/// Allow integers with ``ValueOptions/formatAsHexadecimal`` to be emitted as hexadecimal.
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/namespacetoml.html#a2102aa80bc57783d96180f36e1f64f6aa41e4d7c47742f8f5b60161cc594b169b).
	public static let allowHexadecimalIntegers = Self(rawValue: 1 << 8)

	/// Apply indentation to tables nested within other tables/arrays.
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/namespacetoml.html#a2102aa80bc57783d96180f36e1f64f6aa4ccbf147a4e194e7d2ae2b242e1eeceb).
	public static let indentSubTables = Self(rawValue: 1 << 9)

	/// Apply indentation to array elements when the array is forced to wrap over multiple lines.
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/namespacetoml.html#a2102aa80bc57783d96180f36e1f64f6aa8bf21ed1736197d191a147317c7ea95b).
	public static let indentArrayElements = Self(rawValue: 1 << 10)

	/// Combination mask of all indentation-enabling flags.
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/namespacetoml.html#a2102aa80bc57783d96180f36e1f64f6aa449072e30b43d04b744f22522a880818).
	public static let indentations = Self(rawValue: Self.indentSubTables.rawValue | Self.indentArrayElements.rawValue)

	/// Emit floating-point values with relaxed (human-friendly) precision.
	///
	/// - Warning: Setting this flag may cause serialized documents to no longer round-trip correctly since floats might
	/// have a less precise value upon being written out than they did when being read in. Use this flag at your own risk.
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/namespacetoml.html#a2102aa80bc57783d96180f36e1f64f6aa2023489f273b06937dd37c25b2cf2078).
	public static let relaxedFloatPrecision = Self(rawValue: 1 << 11)
}
