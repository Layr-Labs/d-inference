// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

/// Formatting options for TOML integers.
public enum ValueOptions: UInt16 {
	/// The value will not be formatted.
	case none = 0

	/// Format integer values as binary.
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/namespacetoml.html#afb4d25262a72170134337eb67e6793dea3d21a9285de175ffffc99cfa13df21df).
	case formatAsBinary = 1

	/// Format integer values as octal.
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/namespacetoml.html#afb4d25262a72170134337eb67e6793deadfc26763754dabbdf97d3c8833a2e8ba).
	case formatAsOctal = 2

	/// Format integer values as hexadecimal.
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/namespacetoml.html#afb4d25262a72170134337eb67e6793dea4dd3fec464b7da02debfbc0bd4725c29).
	case formatAsHexadecimal = 3
}
