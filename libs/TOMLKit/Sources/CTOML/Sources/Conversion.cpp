// Copyright (c) 2021 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

#ifdef __cplusplus

	#include "Conversion.hpp"

CTOMLDate tomlDateToCTOMLDate(toml::date date) {
	return CTOMLDate { .year = date.year, .month = date.month, .day = date.day };
}

toml::date cTOMLDateToTomlDate(CTOMLDate date) {
	return toml::date(date.year, date.month, date.day);
}

CTOMLTime tomlTimeToCTOMLTime(toml::time time) {
	return CTOMLTime { .hour = time.hour,
					   .minute = time.minute,
					   .second = time.second,
					   .nanoSecond = time.nanosecond };
}

toml::time cTOMLTimeToTomlTime(CTOMLTime time) {
	return toml::time(time.hour, time.minute, time.second, time.nanoSecond);
}

CTOMLDateTime tomlDateTimeToCTOMLDateTime(toml::date_time dateTime) {
	return CTOMLDateTime {
		.date = tomlDateToCTOMLDate(dateTime.date),
		.time = tomlTimeToCTOMLTime(dateTime.time),
		.offset = dateTime.offset.has_value()
					  ? new CTOMLTimeOffset { .minutes = dateTime.offset.value().minutes }
					  : NULL
	};
}

toml::date_time cTOMLDateTimeToTomlDateTime(CTOMLDateTime dateTime) {
	return toml::date_time(
		cTOMLDateToTomlDate(dateTime.date), cTOMLTimeToTomlTime(dateTime.time),
		dateTime.offset ? toml::time_offset(
							  static_cast<int8_t>(dateTime.offset->minutes / 60),
							  static_cast<int8_t>(dateTime.offset->minutes % 60))
						: toml::time_offset(0, 0));
}

#endif
