// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

import CTOML

/// The position in the TOML document at which a parsing error occurred.
public struct TOMLSourcePosition: Equatable, CustomDebugStringConvertible {
	/// The line at which a parsing error occurred.
	public let line: Int

	/// The column at which a parsing error occurred.
	public let column: Int

	public var debugDescription: String { "line \(self.line), column \(self.column)" }

	init(line: Int, column: Int) {
		self.line = line
		self.column = column
	}

	init(cTOMLSourcePosition: CTOMLSourcePosition) {
		self.line = Int(cTOMLSourcePosition.line)
		self.column = Int(cTOMLSourcePosition.column)
	}
}

public struct TOMLSourceRegion: Equatable, CustomDebugStringConvertible {
	public let begin: TOMLSourcePosition
	public let end: TOMLSourcePosition

	init(begin: TOMLSourcePosition, end: TOMLSourcePosition) {
		self.begin = begin
		self.end = end
	}

	init(cBegin: CTOMLSourcePosition, cEnd: CTOMLSourcePosition) {
		self.begin = .init(cTOMLSourcePosition: cBegin)
		self.end = .init(cTOMLSourcePosition: cEnd)
	}

	public var debugDescription: String {
		self.begin == self.end ? "at \(self.begin)" : "from \(self.begin) to \(self.end)"
	}
}

/// An error that occurs while parsing a TOML document.
public struct TOMLParseError: Error, CustomDebugStringConvertible {
	/// A textual description of the error.
	public let description: String

	/// Returns the region of the source document responsible for the error.
	///
	/// This documentation comment was taken from the [toml++ documentation](https://marzer.github.io/tomlplusplus/classtoml_1_1parse__error.html#a8168b4941305654cf4ba8fc96efd0514).
	public let source: TOMLSourceRegion

	init(cTOMLParseError: CTOMLParseError) {
		self.description = String(cString: cTOMLParseError.description)
		self.source = TOMLSourceRegion(cBegin: cTOMLParseError.source.begin, cEnd: cTOMLParseError.source.end)
	}

	public var debugDescription: String { "\(self.description) (\(self.source))" }
}
