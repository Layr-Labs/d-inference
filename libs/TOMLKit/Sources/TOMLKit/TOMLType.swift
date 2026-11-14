// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

import CTOML

/// TOML data types.
public enum TOMLType: String, CaseIterable, CustomStringConvertible {
	/// A [TOML table](https://toml.io/en/v1.0.0#table).
	case table

	/// A [TOML array](https://toml.io/en/v1.0.0#array).
	case array

	/// A [TOML string](https://toml.io/en/v1.0.0#string).
	case string

	/// A [TOML integer](https://toml.io/en/v1.0.0#integer).
	case int

	/// A [TOML floating-point](https://toml.io/en/v1.0.0#float) (double) value.
	case double

	/// A [TOML boolean](https://toml.io/en/v1.0.0#boolean).
	case bool

	/// A [TOML date](https://toml.io/en/v1.0.0#local-date).
	case date

	/// A [TOML time](https://toml.io/en/v1.0.0#local-time).
	case time

	/// A [TOML date with time](https://toml.io/en/v1.0.0#offset-date-time).
	case dateTime

	init(cTOMLNodeType: CTOMLNodeType) {
		self = cTOMLNodeType.tomlType
	}

	public var description: String {
		switch self {
			case .int: return "integer"
			case .double: return "floating-point number"
			case .dateTime: return "date-time"
			default: return self.rawValue
		}
	}
}

extension CTOMLNodeType {
	var tomlType: TOMLType {
		switch self {
			case CTOMLNodeType.array:
				return .array
			case CTOMLNodeType.boolean:
				return .bool
			case CTOMLNodeType.date:
				return .date
			case CTOMLNodeType.dateTime:
				return .dateTime
			case CTOMLNodeType.floatingPoint:
				return .double
			case CTOMLNodeType.integer:
				return .int
			case CTOMLNodeType.string:
				return .string
			case CTOMLNodeType.table:
				return .table
			case CTOMLNodeType.timeType:
				return .time
		}
	}
}
