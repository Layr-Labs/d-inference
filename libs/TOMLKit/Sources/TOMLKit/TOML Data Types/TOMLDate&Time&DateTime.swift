// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

import CTOML

#if canImport(Darwin)
	import Darwin.C
#elseif canImport(Glibc)
	import Glibc
#elseif canImport(ucrt)
	import ucrt
#else
	#error("Unsupported Platform")
#endif

import struct Foundation.Calendar
import struct Foundation.Date
import struct Foundation.DateComponents

/// A [date](https://toml.io/en/v1.0.0#local-date) in a TOML document.
public struct TOMLDate: Codable, Equatable, CustomDebugStringConvertible, TOMLValueConvertible {
	public var year: Int
	public var month: Int
	public var day: Int

	public var type: TOMLType { .date }
	var cTOMLDate: CTOMLDate {
		CTOMLDate(year: UInt16(self.year), month: UInt8(self.month), day: UInt8(self.day))
	}

	public var tomlValue: TOMLValue { get { .init(self) } set {} }

	public var debugDescription: String {
		String(freeing: cTOMLDateToTOML(self.cTOMLDate))
	}

	public init(year: Int, month: Int, day: Int) {
		self.year = year
		self.month = month
		self.day = day
	}

	public init?(date: Date) {
		let calendar = Calendar.current
		let c = calendar.dateComponents([.year, .month, .day], from: date)

		guard let y = c.year, let m = c.month, let d = c.day else { return nil }

		self.year = y
		self.month = m
		self.day = d
	}

	init(cTOMLDate: CTOMLDate) {
		self.year = Int(cTOMLDate.year)
		self.month = Int(cTOMLDate.month)
		self.day = Int(cTOMLDate.day)
	}

	public var date: Date? {
		let calendar = Calendar.current
		let dateComponents = DateComponents(
			calendar: calendar,
			year: self.year,
			month: self.month,
			day: self.day
		)

		return calendar.date(from: dateComponents)
	}

	public static func == (lhs: TOMLDate, rhs: TOMLDate) -> Bool {
		lhs.year == rhs.year &&
			lhs.month == rhs.month &&
			lhs.day == rhs.day
	}
}

/// A [time](https://toml.io/en/v1.0.0#local-time) in a TOML document.
public struct TOMLTime: Codable, Equatable, CustomDebugStringConvertible, TOMLValueConvertible {
	public var hour: Int
	public var minute: Int
	public var second: Int
	public var nanoSecond: Int

	public var type: TOMLType { .time }

	var cTOMLTime: CTOMLTime {
		CTOMLTime(
			hour: UInt8(self.hour),
			minute: UInt8(self.minute),
			second: UInt8(self.second),
			nanoSecond: UInt32(self.nanoSecond)
		)
	}

	public var debugDescription: String {
		String(freeing: cTOMLTimeToTOML(self.cTOMLTime))
	}

	public var tomlValue: TOMLValue { get { .init(self) } set {} }

	public init(hour: Int, minute: Int, second: Int, nanoSecond: Int) {
		self.hour = hour
		self.minute = minute
		self.second = second
		self.nanoSecond = nanoSecond
	}

	init(cTOMLTime: CTOMLTime) {
		self.hour = Int(cTOMLTime.hour)
		self.minute = Int(cTOMLTime.minute)
		self.second = Int(cTOMLTime.second)
		self.nanoSecond = Int(cTOMLTime.nanoSecond)
	}

	public static func == (lhs: TOMLTime, rhs: TOMLTime) -> Bool {
		lhs.hour == rhs.hour &&
			lhs.minute == rhs.minute &&
			lhs.second == rhs.second &&
			lhs.nanoSecond == rhs.nanoSecond
	}
}

/// A [time offset](https://toml.io/en/v1.0.0#offset-date-time) for ``TOMLDateTime``.
public struct TOMLTimeOffset: Codable, Equatable {
	public var offset: Int

	var cTOMLTimeOffset: CTOMLTimeOffset {
		CTOMLTimeOffset(minutes: Int16(self.offset))
	}

	public init(offset: Int) {
		self.offset = offset
	}

	public init(hours: Int, minutes: Int) {
		self.offset = (hours * 60) + minutes
	}

	init(cTOMLTimeOffset: CTOMLTimeOffset) {
		self.offset = Int(cTOMLTimeOffset.minutes)
	}
}

/// A [date and time](https://toml.io/en/v1.0.0#local-date-time) in a TOML document.
public struct TOMLDateTime: Codable, Equatable, CustomDebugStringConvertible, TOMLValueConvertible {
	public var date: TOMLDate
	public var time: TOMLTime
	public internal(set) var offset: TOMLTimeOffset?

	/// Calls `body` with this date and time as a `CTOMLDateTime`, whose offset points to storage that lasts only for
	/// the call.
	func withCTOMLDateTime<Result>(_ body: (CTOMLDateTime) -> Result) -> Result {
		guard let offset = self.offset else {
			return body(CTOMLDateTime(date: self.date.cTOMLDate, time: self.time.cTOMLTime, offset: nil))
		}

		var cTOMLTimeOffset = offset.cTOMLTimeOffset
		return withUnsafeMutablePointer(to: &cTOMLTimeOffset) {
			body(CTOMLDateTime(date: self.date.cTOMLDate, time: self.time.cTOMLTime, offset: $0))
		}
	}

	public var tomlValue: TOMLValue { get { .init(self) } set {} }

	public var debugDescription: String {
		self.withCTOMLDateTime { String(freeing: cTOMLDateTimeToTOML($0)) }
	}

	public var type: TOMLType { .dateTime }

	/// Creates a `Foundation.Date` from `self`.
	public var fDate: Date? {
		let calendar = Calendar.current
		let dateComponents = DateComponents(
			calendar: calendar,
			year: self.date.year,
			month: self.date.month,
			day: self.date.day,
			hour: self.time.hour,
			minute: self.time.minute,
			second: self.time.second,
			nanosecond: self.time.nanoSecond
		)

		return calendar.date(from: dateComponents)
	}

	init(cTOMLDateTime: CTOMLDateTime) {
		self.date = TOMLDate(cTOMLDate: cTOMLDateTime.date)
		self.time = TOMLTime(cTOMLTime: cTOMLDateTime.time)
		if let off = cTOMLDateTime.offset {
			self.offset = TOMLTimeOffset(cTOMLTimeOffset: off.pointee)
		}
	}

	public init?(date: Date) {
		let calendar = Calendar.current
		let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)

		guard
			let date = TOMLDate(date: date),
			let hour = c.hour,
			let minute = c.minute,
			let second = c.second,
			let nanoSecond = c.nanosecond
		else { return nil }

		self.date = date

		self.time = TOMLTime(hour: hour, minute: minute, second: second, nanoSecond: nanoSecond)
	}

	public init(date: TOMLDate, time: TOMLTime, offset: TOMLTimeOffset? = nil) {
		self.date = date
		self.time = time
		self.offset = offset
	}

	public static func == (lhs: TOMLDateTime, rhs: TOMLDateTime) -> Bool {
		lhs.date == rhs.date &&
			lhs.time == rhs.time &&
			lhs.offset == rhs.offset
	}
}
