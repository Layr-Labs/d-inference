
#include "Conversion.hpp"
#include "toml.hpp"
#include <CTOML/CTOML.h>
#include <string>

/// Convert \c date to TOML.
const char * _Nonnull cTOMLDateToTOML(CTOMLDate date) {
	std::stringstream ss;

	ss << cTOMLDateToTomlDate(date);

	return strdup(ss.str().c_str());
}

/// Convert \c time to TOML.
const char * _Nonnull cTOMLTimeToTOML(CTOMLTime time) {
	std::stringstream ss;

	ss << cTOMLTimeToTomlTime(time);

	return strdup(ss.str().c_str());
}

/// Convert \c dateTime to TOML.
const char * _Nonnull cTOMLDateTimeToTOML(CTOMLDateTime dateTime) {
	std::stringstream ss;

	ss << cTOMLDateTimeToTomlDateTime(dateTime);

	return strdup(ss.str().c_str());
}
