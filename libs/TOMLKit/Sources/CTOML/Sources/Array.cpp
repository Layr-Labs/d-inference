// Copyright (c) 2021 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

#include "Conversion.hpp"
#include "toml.hpp"
#include <CTOML/CTOML.h>

#ifdef __cplusplus
extern "C" {
#endif

	// MARK: - Creation and Deletion

	/// Initializes a new \c toml::array .
	CTOMLArray * arrayCreate() { return reinterpret_cast<CTOMLArray *>(new toml::array()); }

	// MARK: - Array Information

	/// Checks whether \c array1 is equal to \c array2 .
	/// @param array1 This first \c toml::array that will be used in the comparison.
	/// @param array2 This second \c toml::array that will be used in the comparison.
	bool arrayEqual(CTOMLArray * array1, CTOMLArray * array2) {
		auto arr1 = *reinterpret_cast<toml::array *>(array1);
		auto arr2 = *reinterpret_cast<toml::array *>(array2);
		return arr1 == arr2;
	}

	/// Whether \c array is empty or not.
	bool arrayIsEmpty(CTOMLArray * array) {
		return reinterpret_cast<toml::array *>(array)->empty();
	}

	/// The amount of elements in \c array .
	size_t arraySize(CTOMLArray * array) { return reinterpret_cast<toml::array *>(array)->size(); }

	/// Clears all the values in \c array .
	/// @param array The \c toml::array to clear.
	void arrayClear(CTOMLArray * array) { reinterpret_cast<toml::array *>(array)->clear(); }

	// MARK: - Value Insertion

	/// Insert a \c int64_t into \c array .
	void arrayInsertInt(CTOMLArray * array, int64_t index, int64_t integer, uint16_t flags) {
		auto arr = reinterpret_cast<toml::array *>(array);
		arr->insert(arr->cbegin() + index, integer, toml::value_flags(flags));
	}

	/// Insert a \c toml::table into \c array .
	void arrayInsertTable(CTOMLArray * array, int64_t index, CTOMLTable * _Nonnull table) {
		auto arr = reinterpret_cast<toml::array *>(array);
		arr->emplace<toml::table>(arr->cbegin() + index, *reinterpret_cast<toml::table *>(table));
	}

	/// Insert a \c toml::array into \c array .
	void arrayInsertArray(CTOMLArray * array, int64_t index, CTOMLArray * _Nonnull array2) {
		auto arr = reinterpret_cast<toml::array *>(array);
		arr->emplace<toml::array>(arr->cbegin() + index, *reinterpret_cast<toml::array *>(array2));
	}

	/// Insert a \c toml::node into \c array.
	void arrayInsertNode(CTOMLArray * array, int64_t index, CTOMLNode * _Nonnull node) {
		auto arr = reinterpret_cast<toml::array *>(array);
		arr->insert(arr->cbegin() + index, *reinterpret_cast<toml::node *>(node));
	}

	/// Replace the \c bool at \c index with \c b .
	void arrayReplaceBool(CTOMLArray * array, int64_t index, bool b) {
		auto arr = reinterpret_cast<toml::array *>(array);

		if (arr->get(index)) {
			arr->replace(arr->cbegin() + index, b);
		} else {
			arr->insert(arr->cbegin() + index, b);
		}
	}

	/// Replace the \c int64_t at \c index with \c i .
	void arrayReplaceInt(CTOMLArray * array, int64_t index, int64_t i, uint16_t flags) {
		auto arr = reinterpret_cast<toml::array *>(array);
		auto v = toml::value(i);

		if (arr->get(index)) {
			arr->replace(arr->cbegin() + index, i, toml::value_flags(flags));
		} else {
			arr->insert(arr->cbegin() + index, i, toml::value_flags(flags));
		}
	}

	/// Replace the \c double at \c index with \c d .
	void arrayReplaceDouble(CTOMLArray * array, int64_t index, double d) {
		auto arr = reinterpret_cast<toml::array *>(array);

		if (arr->get(index)) {
			arr->replace(arr->cbegin() + index, d);
		} else {
			arr->insert(arr->cbegin() + index, d);
		}
	}

	/// Replace the \c std::string at \c index with \c s .
	void arrayReplaceString(CTOMLArray * array, int64_t index, const char * s) {
		auto arr = reinterpret_cast<toml::array *>(array);

		if (arr->get(index)) {
			arr->replace(arr->cbegin() + index, s);
		} else {
			arr->insert(arr->cbegin() + index, s);
		}
	}

	/// Replace the \c toml::date at \c index with \c date .
	void arrayReplaceDate(CTOMLArray * array, int64_t index, CTOMLDate date) {
		auto arr = reinterpret_cast<toml::array *>(array);

		if (arr->get(index)) {
			arr->replace(arr->cbegin() + index, cTOMLDateToTomlDate(date));
		} else {
			arr->insert(arr->cbegin() + index, cTOMLDateToTomlDate(date));
		}
	}

	/// Replace the \c toml::time at \c index with \c time .
	void arrayReplaceTime(CTOMLArray * array, int64_t index, CTOMLTime time) {
		auto arr = reinterpret_cast<toml::array *>(array);

		if (arr->get(index)) {
			arr->replace(arr->cbegin() + index, cTOMLTimeToTomlTime(time));
		} else {
			arr->insert(arr->cbegin() + index, cTOMLTimeToTomlTime(time));
		}
	}

	/// Replace the \c toml::date_time at \c index with \c dateTime .
	void arrayReplaceDateTime(CTOMLArray * array, int64_t index, CTOMLDateTime dateTime) {
		auto arr = reinterpret_cast<toml::array *>(array);

		if (arr->get(index)) {
			arr->replace(arr->cbegin() + index, cTOMLDateTimeToTomlDateTime(dateTime));
		} else {
			arr->insert(arr->cbegin() + index, cTOMLDateTimeToTomlDateTime(dateTime));
		}
	}

	/// Replace the \c toml::array at \c index with \c arrayToEmplace .
	void
	arrayReplaceArray(CTOMLArray * array, int64_t index, CTOMLArray * _Nonnull arrayToEmplace) {
		auto arr = reinterpret_cast<toml::array *>(array);

		// FIXME: If we don't create a new `toml::array`, sometimes accessing `arrToInsert` crashes.
		// Also, creating a new `toml::array` is inefficient.
		auto arrToInsert = toml::array(*reinterpret_cast<toml::array *>(arrayToEmplace));
		// auto arrToInsert = reinterpret_cast<toml::array *>(arrayToEmplace);

		if (arr->get(index)) {
			arr->replace(arr->cbegin() + index, arrToInsert);
		} else {
			arr->insert(arr->cbegin() + index, arrToInsert);
		}
	}

	/// Replace the \c toml::table at \c index with \c table .
	void arrayReplaceTable(CTOMLArray * array, int64_t index, CTOMLTable * _Nonnull table) {
		auto arr = reinterpret_cast<toml::array *>(array);

		if (arr->get(index)) {
			arr->replace(arr->cbegin() + index, *reinterpret_cast<toml::table *>(table));
		} else {
			arr->insert(arr->cbegin() + index, *reinterpret_cast<toml::table *>(table));
		}
	}

	// MARK: - Value Retrieval

	/// Retrieves a \c toml::node from \c array at \c index .
	CTOMLNode * _Nonnull arrayGetNode(CTOMLArray * array, int64_t index) {
		return reinterpret_cast<CTOMLNode *>(reinterpret_cast<toml::array *>(array)->get(index));
	}

	// MARK: - Value Removal

	/// Removes the element at \c index from \c array .
	void arrayRemoveElement(CTOMLArray * array, int64_t index) {
		auto arr = reinterpret_cast<toml::array *>(array);
		arr->erase(arr->cbegin() + index);
	}

	// MARK: - Array Printing

	const char * _Nonnull arrayConvertToTOML(CTOMLArray * _Nonnull array) {
		std::stringstream ss;

		ss << toml::toml_formatter(*reinterpret_cast<toml::array *>(array));

		return strdup(ss.str().c_str());
	}

#ifdef __cplusplus
}
#endif
