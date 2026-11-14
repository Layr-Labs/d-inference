// Copyright (c) 2021 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

#ifndef CTOML_H
#define CTOML_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

	// MARK: - Structs

	struct CTOMLTable;
	typedef struct CTOMLTable CTOMLTable;

	struct CTOMLArray;
	typedef struct CTOMLArray CTOMLArray;

	struct CTOMLNode;
	typedef struct CTOMLNode CTOMLNode;

	struct CTOMLValue;
	typedef struct CTOMLValue CTOMLValue;

	/// The position in the TOML document at which a parsing error occurred.
	struct CTOMLSourcePosition {

		/// The line at which a parsing error occurred.
		uint32_t line;

		/// The column at which a parsing error occurred.
		uint32_t column;
	};
	typedef struct CTOMLSourcePosition CTOMLSourcePosition;

	struct CTOMLSourceRegion {
		CTOMLSourcePosition begin;
		CTOMLSourcePosition end;
	};

	typedef struct CTOMLSourceRegion CTOMLSourceRegion;

	/// An error that occurs while parsing a TOML document.
	struct CTOMLParseError {
		/// A textual description of the error.
		const char * _Nonnull description;

		/// Returns the region of the source document responsible for the error.
		///
		/// This documentation comment was taken from the [toml++
		/// documentation](https://marzer.github.io/tomlplusplus/classtoml_1_1parse__error.html#a8168b4941305654cf4ba8fc96efd0514)
		/// .
		CTOMLSourceRegion source;
	};

	typedef struct CTOMLParseError CTOMLParseError;

	/// A date in a TOML document.
	struct CTOMLDate {
		uint16_t year;
		uint8_t month;
		uint8_t day;
	};
	typedef struct CTOMLDate CTOMLDate;

	/// A time in a TOML document.
	struct CTOMLTime {
		uint8_t hour;
		uint8_t minute;
		uint8_t second;
		uint32_t nanoSecond;
	};
	typedef struct CTOMLTime CTOMLTime;

	struct CTOMLTimeOffset {
		int16_t minutes;
	};
	typedef struct CTOMLTimeOffset CTOMLTimeOffset;

	/// A date and time in a TOML document.
	struct CTOMLDateTime {
		CTOMLDate date;
		CTOMLTime time;
		CTOMLTimeOffset * _Nullable offset;
	};
	typedef struct CTOMLDateTime CTOMLDateTime;

	/// TOML data types.
	enum CTOMLNodeType {
		/// A TOML table.
		table,

		/// A TOML array.
		array,

		/// A TOML string.
		string,

		/// A TOML integer.
		integer,

		/// A TOML floating-point value.
		floatingPoint,

		/// A TOML boolean.
		boolean,

		/// A TOML date.
		date,

		/// A TOML time.
		timeType,

		/// A TOML date with time.
		dateTime
	} __attribute__((enum_extensibility(closed)));

	typedef enum CTOMLNodeType CTOMLNodeType;

#pragma clang assume_nonnull begin

	// MARK: - Array - Creation and Deletion

	/// Initializes a new \c toml::array .
	CTOMLArray * arrayCreate();

	// MARK: - Array - Information

	/// Checks whether \c array1 is equal to \c array2 .
	/// @param array1 This first \c toml::array that will be used in the comparison.
	/// @param array2 This second \c toml::array that will be used in the comparison.
	bool arrayEqual(CTOMLArray * array1, CTOMLArray * array2);

	/// Whether \c array is empty or not.
	bool arrayIsEmpty(CTOMLArray * array);

	/// The amount of elements in \c array .
	size_t arraySize(CTOMLArray * array);

	// MARK: - Array - Value Manipulation - Deletion
	/// Clears all the values in \c array .
	/// @param array The \c toml::array to clear.
	void arrayClear(CTOMLArray * array);

	/// Removes the element at \c index from \c array .
	void arrayRemoveElement(CTOMLArray * array, int64_t index);

	/// Convert \c array to TOML.
	const char * _Nonnull arrayConvertToTOML(CTOMLArray * _Nonnull array);

	// MARK: - Array - Value Manipulation - Insertion

	/// Insert a \c int64_t into \c array .
	void arrayInsertInt(CTOMLArray * array, int64_t index, int64_t integer, uint16_t flags);

	/// Insert a \c toml::table into \c array .
	void arrayInsertTable(CTOMLArray * array, int64_t index, CTOMLTable * _Nonnull table);

	/// Insert a \c toml::array into \c array .
	void arrayInsertArray(CTOMLArray * array, int64_t index, CTOMLArray * _Nonnull array2);

	/// Insert a \c toml::node into \c array.
	void arrayInsertNode(CTOMLArray * array, int64_t index, CTOMLNode * _Nonnull node);

	/// Replace the \c bool at \c index with \c b .
	void arrayReplaceBool(CTOMLArray * array, int64_t index, bool b);

	/// Replace the \c int64_t at \c index with \c i .
	void arrayReplaceInt(CTOMLArray * array, int64_t index, int64_t i, uint16_t flags);

	/// Replace the \c double at \c index with \c d .
	void arrayReplaceDouble(CTOMLArray * array, int64_t index, double d);

	/// Replace the \c std::string at \c index with \c s .
	void arrayReplaceString(CTOMLArray * array, int64_t index, const char * s);

	/// Replace the \c toml::date at \c index with \c date .
	void arrayReplaceDate(CTOMLArray * array, int64_t index, CTOMLDate date);

	/// Replace the \c toml::time at \c index with \c time .
	void arrayReplaceTime(CTOMLArray * array, int64_t index, CTOMLTime time);

	/// Replace the \c toml::date_time at \c index with \c dateTime .
	void arrayReplaceDateTime(CTOMLArray * array, int64_t index, CTOMLDateTime dateTime);

	/// Replace the \c toml::array at \c index with \c arrayToEmplace .
	void arrayReplaceArray(CTOMLArray * array, int64_t index, CTOMLArray * _Nonnull arrayToEmplace);

	/// Replace the \c toml::table at \c index with \c table .
	void arrayReplaceTable(CTOMLArray * array, int64_t index, CTOMLTable * _Nonnull table);

	/// Replaces the value at \c key with \c integer .
	void
	tableReplaceOrInsertInt(CTOMLTable * table, const char * key, int64_t integer, uint16_t flags);

	/// Replaces the value at \c key with \c tableToInsert .
	void
	tableReplaceOrInsertTable(CTOMLTable * table, const char * key, CTOMLTable * tableToInsert);

	/// Replaces the value at \c key with \c array .
	void tableReplaceOrInsertArray(CTOMLTable * table, const char * key, CTOMLArray * array);

	// Replaces the value at \c key with \c toml::node .
	void tableReplaceOrInsertNode(CTOMLTable * table, const char * key, CTOMLNode * node);

	// MARK: - Array - Value Retrieval
	/// Retrieves a \c toml::node from \c array at \c index .
	CTOMLNode * arrayGetNode(CTOMLArray * array, int64_t index);

	// MARK: - Table - Creation and Deletion
	/// Initializes a new \c toml::table .
	CTOMLTable * tableCreate();

	/// Creates a \c toml::table from a string containing a TOML document.
	/// @param tomlStr The string containing the TOML document.
	/// @param errorPointer Te pointer that will contain the \c CTOMLParseError if an error occurs
	/// during parsing.
	CTOMLTable * _Nullable tableCreateFromString(
		const char * _Nonnull tomlStr, CTOMLParseError * _Nonnull errorPointer);

	// MARK: - Table - Information

	/// Checks whether \c table1 is equal to \c table2 .
	/// @param table1 This first \c toml::table that will be used in the comparison.
	/// @param table2 This second \c toml::table that will be used in the comparison.
	bool tableEqual(CTOMLTable * table1, CTOMLTable * table2);

	/// Makes \c table an inline table or not an inline table depending on the value of \c isInline
	/// .
	/// @param table The \c toml::table to inline or not inline.
	/// @param isInline Whether \c table should be made an inline table or not.
	void tableSetInline(CTOMLTable * table, bool isInline);

	/// Check if \c table is inlined.
	bool tableInline(CTOMLTable * table);

	/// Whether \c table is empty or not.
	bool tableIsEmpty(CTOMLTable * table);

	/// Checks if \c table is homogeneous.
	bool tableIsHomogeneous(CTOMLTable * table);

	/// The amount of elements in \c table .
	size_t tableSize(CTOMLTable * table);

	/// Whether the \c table contains \c key .
	bool tableContains(CTOMLTable * table, const char * key);

	// MARK: - Table - Data Insertion

	/// Clears all the values in \c table.
	/// @param table The \c toml::table to clear.
	void tableClear(CTOMLTable * table);

	/// Inserts \c integer into \c table at \c key .
	void tableInsertInt(CTOMLTable * table, const char * key, int64_t integer, uint16_t flags);

	/// Inserts \c tableToInsert into \c table at \c key .
	void tableInsertTable(CTOMLTable * table, const char * key, CTOMLTable * tableToInsert);

	/// Inserts \c array into \c table at \c key .
	void tableInsertArray(CTOMLTable * table, const char * key, CTOMLArray * array);

	/// Inserts \c toml::node into \c table at \c key .
	void tableInsertNode(CTOMLTable * table, const char * key, CTOMLNode * node);

	// MARK: - Table - Data Retrieval

	/// Retrieves a \c toml::node from \c table at \c key .
	CTOMLNode * _Nullable tableGetNode(CTOMLTable * table, const char * key);

	/// Retrieve all the keys from \c table . The size of the return value is the size of \c table .
	char const * _Nonnull const * _Nonnull tableGetKeys(CTOMLTable * table);

	/// Retrieve all the values from \c table . The size of the return value is the size of \c table
	/// .
	CTOMLNode const * _Nonnull const * _Nonnull tableGetValues(CTOMLTable * table);

	// MARK: - Table - Data Removal
	/// Remove the element at \c key from \c table .
	void tableRemoveElement(CTOMLTable * table, const char * key);

	// MARK: - Table Conversion

	/// Convert \c table to a TOML document.
	char * tableConvertToTOML(CTOMLTable * table, uint64_t options);

	/// Convert \c table to a JSON document.
	char * tableConvertToJSON(CTOMLTable * table, uint64_t options);

	/// Convert \c table to a YAML document.
	char * tableConvertToYAML(CTOMLTable * table, uint64_t options);

	// MARK: - Node - Information
	/// The TOML type of \c node .
	CTOMLNodeType nodeType(CTOMLNode * node);

	/// Copies \c n and returns the copy.
	CTOMLNode * copyNode(CTOMLNode * n);

	// MARK: - Node - Deletion

	/// Deletes \c node with every node it holds. \c node must be a root this bridge allocated (\c tableCreate ,
	/// \c tableCreateFromString , \c arrayCreate , \c copyNode or a \c nodeFrom function other than \c nodeFromTable
	/// and \c nodeFromArray ), never a node inside a table or an array.
	void nodeDelete(CTOMLNode * node);

	/// Frees a \c CTOMLDateTime that \c nodeAsDateTime returned, with its offset.
	void dateTimeFree(const CTOMLDateTime * dateTime);

	// MARK: - Date, Time, and Date Time Conversion
	/// Convert \c date to TOML.
	const char * _Nonnull cTOMLDateToTOML(CTOMLDate date);

	/// Convert \c time to TOML.
	const char * _Nonnull cTOMLTimeToTOML(CTOMLTime time);

	/// Convert \c dateTime to TOML.
	const char * _Nonnull cTOMLDateTimeToTOML(CTOMLDateTime dateTime);
#pragma clang assume_nonnull end

	// MARK: - Node - Creation

	/// Creates a \c CTOMLNode from \c b .
	CTOMLNode * _Nonnull nodeFromBool(bool b);

	// Creates a \c CTOMLNode from \c i .
	CTOMLNode * _Nonnull nodeFromInt(int64_t i);

	/// Creates a \c CTOMLNode from \c d .
	CTOMLNode * _Nonnull nodeFromDouble(double d);

	/// Creates a \c CTOMLNode from \c s .
	CTOMLNode * _Nonnull nodeFromString(const char * _Nonnull s);

	/// Creates a \c CTOMLNode from \c d .
	CTOMLNode * _Nonnull nodeFromDate(CTOMLDate d);

	/// Creates a \c CTOMLNode from \c t .
	CTOMLNode * _Nonnull nodeFromTime(CTOMLTime t);

	/// Creates a \c CTOMLNode from \c dt .
	CTOMLNode * _Nonnull nodeFromDateTime(CTOMLDateTime dt);

	/// Creates a \c CTOMLNode from \c t .
	CTOMLNode * _Nonnull nodeFromTable(CTOMLTable * _Nonnull t);

	/// Creates a \c CTOMLNode from \c a .
	CTOMLNode * _Nonnull nodeFromArray(CTOMLTable * _Nonnull a);

	// MARK: - Node - Data Retrieval

	/// Retrieves a \c bool from the \c node .
	const bool * _Nullable nodeAsBool(CTOMLNode * _Nonnull node);

	/// Retrieves a \c int64_t from the \c node .
	const int64_t * _Nullable nodeAsInt(CTOMLNode * _Nonnull node);
	/// Retrieves a \c double from the \c node .
	const double * _Nullable nodeAsDouble(CTOMLNode * _Nonnull node);

	/// Retrieves a \c char * from the \c node .
	const char * _Nullable nodeAsString(CTOMLNode * _Nonnull node);

	/// Retrieves a \c CTOMLDate from the \c node .
	const CTOMLDate * _Nullable nodeAsDate(CTOMLNode * _Nonnull node);

	/// Retrieves a \c CTOMLTime from the \c node .
	const CTOMLTime * _Nullable nodeAsTime(CTOMLNode * _Nonnull node);

	/// Retrieves a \c CTOMLDateTime from the \c node .
	const CTOMLDateTime * _Nullable nodeAsDateTime(CTOMLNode * _Nonnull node);

	/// Retrieves a \c CTOMLTable from the \c node .
	CTOMLTable * _Nullable nodeAsTable(CTOMLNode * _Nonnull node);

	/// Retrieves a \c CTOMLArray from the \c node .
	CTOMLArray * _Nullable nodeAsArray(CTOMLNode * _Nonnull node);

#ifdef __cplusplus
}
#endif

#endif /* CTOML_H */
