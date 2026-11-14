// Copyright (c) 2021 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

#ifndef Conversion_hpp
#define Conversion_hpp

#ifdef __cplusplus

	#include "toml.hpp"
	#include <CTOML/CTOML.h>

// MARK: - Conversion

toml::date cTOMLDateToTomlDate(CTOMLDate date);
CTOMLDate tomlDateToCTOMLDate(toml::date date);
CTOMLTime tomlTimeToCTOMLTime(toml::time time);
toml::time cTOMLTimeToTomlTime(CTOMLTime time);
CTOMLDateTime tomlDateTimeToCTOMLDateTime(toml::date_time dateTime);
toml::date_time cTOMLDateTimeToTomlDateTime(CTOMLDateTime dateTime);

#endif
#endif /* Conversion_hpp */
