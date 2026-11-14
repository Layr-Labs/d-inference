// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

extension UInt8: TOMLValueConvertible {
	public var debugDescription: String { self.description }
	public var type: TOMLType { .int }
	public var tomlValue: TOMLValue { get { .init(self) } set {} }
}

extension UInt16: TOMLValueConvertible {
	public var debugDescription: String { self.description }
	public var type: TOMLType { .int }
	public var tomlValue: TOMLValue { get { .init(self) } set {} }
}

extension UInt32: TOMLValueConvertible {
	public var debugDescription: String { self.description }
	public var type: TOMLType { .int }
	public var tomlValue: TOMLValue { get { .init(self) } set {} }
}

extension UInt64: TOMLValueConvertible {
	public var debugDescription: String { self.description }
	public var type: TOMLType { .int }
	public var tomlValue: TOMLValue { get { .init(self) } set {} }
}

extension UInt: TOMLValueConvertible {
	public var debugDescription: String { self.description }
	public var type: TOMLType { .int }
	public var tomlValue: TOMLValue { get { .init(self) } set {} }
}

extension Int8: TOMLValueConvertible {
	public var debugDescription: String { self.description }
	public var type: TOMLType { .int }
	public var tomlValue: TOMLValue { get { .init(self) } set {} }
}

extension Int16: TOMLValueConvertible {
	public var debugDescription: String { self.description }
	public var type: TOMLType { .int }
	public var tomlValue: TOMLValue { get { .init(self) } set {} }
}

extension Int32: TOMLValueConvertible {
	public var debugDescription: String { self.description }
	public var type: TOMLType { .int }
	public var tomlValue: TOMLValue { get { .init(self) } set {} }
}

extension Int64: TOMLValueConvertible {
	public var debugDescription: String { self.description }
	public var type: TOMLType { .int }
	public var tomlValue: TOMLValue { get { .init(self) } set {} }
}

extension Int: TOMLValueConvertible {
	public var debugDescription: String { self.description }
	public var type: TOMLType { .int }
	public var tomlValue: TOMLValue { get { .init(self) } set {} }
}
