// Copyright (c) 2021 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

#include "Conversion.hpp"
#include "toml.hpp"
#include <CTOML/CTOML.h>
#include <iostream>

#ifdef __cplusplus
extern "C" {
#endif

	// MARK: - Table Creation and Deletion
	/// Initializes a new \c toml::table .
	CTOMLTable * tableCreate() { return reinterpret_cast<CTOMLTable *>(new toml::table()); }

	/// Creates a \c toml::table from a string containing a TOML document.
	/// @param tomlStr The string containing the TOML document.
	/// @param errorPointer Te pointer that will contain the \c CTOMLParseError if an error occurs
	/// during parsing.
	CTOMLTable * _Nullable tableCreateFromString(
		const char * _Nonnull tomlStr, CTOMLParseError * _Nonnull errorPointer) {
		try {
			return reinterpret_cast<CTOMLTable *>(new toml::table(toml::parse(tomlStr)));
		} catch (toml::parse_error & e) {
			*errorPointer = CTOMLParseError {
				.description = strdup(std::string(e.description()).c_str()),
				.source =
					CTOMLSourceRegion {
						.begin = CTOMLSourcePosition { .line = e.source().begin.line,
													   .column = e.source().begin.column },
						.end = CTOMLSourcePosition { .line = e.source().end.line,
													 .column = e.source().end.column } }
			};

			return NULL;
		}
	}

	// MARK: - Table Information

	/// Checks whether \c table1 is equal to \c table2 .
	/// @param table1 This first \c toml::table that will be used in the comparison.
	/// @param table2 This second \c toml::table that will be used in the comparison.
	bool tableEqual(CTOMLTable * table1, CTOMLTable * table2) {
		auto tbl1 = *reinterpret_cast<toml::table *>(table1);
		auto tbl2 = *reinterpret_cast<toml::table *>(table2);
		return tbl1 == tbl2;
	}

	/// Makes \c table an inline table or not an inline table depending on the value of \c isInline
	/// .
	/// @param table The \c toml::table to inline or not inline.
	/// @param isInline Whether \c table should be made an inline table or not.
	void tableSetInline(CTOMLTable * table, bool isInline) {
		reinterpret_cast<toml::table *>(table)->is_inline(isInline);
	}

	/// Check if \c table is inlined.
	bool tableInline(CTOMLTable * table) {
		return reinterpret_cast<toml::table *>(table)->is_inline();
	}

	/// Whether \c table is empty or not.
	bool tableIsEmpty(CTOMLTable * table) {
		return reinterpret_cast<toml::table *>(table)->empty();
	}

	/// Checks if \c table is homogeneous.
	bool tableIsHomogeneous(CTOMLTable * table) {
		return reinterpret_cast<toml::table *>(table)->is_homogeneous(toml::node_type::none);
	}

	/// The amount of elements in \c table .
	size_t tableSize(CTOMLTable * table) { return reinterpret_cast<toml::table *>(table)->size(); }

	/// Whether the \c table contains \c key .
	bool tableContains(CTOMLTable * table, const char * key) {
		return reinterpret_cast<toml::table *>(table)->contains(key);
	}

	// MARK: - Table - Data Insertion

	/// Clears all the values in \c table.
	/// @param table The \c toml::table to clear.
	void tableClear(CTOMLTable * table) { reinterpret_cast<toml::table *>(table)->clear(); }

	/// Inserts \c integer into \c table at \c key .
	void tableInsertInt(CTOMLTable * table, const char * key, int64_t integer, uint16_t flags) {
		auto t = reinterpret_cast<toml::table *>(table);
		t->insert(key, integer, toml::value_flags(flags));
	}

	/// Inserts \c tableToInsert into \c table at \c key .
	void tableInsertTable(CTOMLTable * table, const char * key, CTOMLTable * tableToInsert) {
		reinterpret_cast<toml::table *>(table)->insert(
			key, *reinterpret_cast<toml::table *>(tableToInsert));
	}

	/// Inserts \c array into \c table at \c key .
	void tableInsertArray(CTOMLTable * table, const char * key, CTOMLArray * array) {
		reinterpret_cast<toml::table *>(table)->insert(
			key, *reinterpret_cast<toml::array *>(array));
	}

	/// Inserts \c toml::node into \c table at \c key .
	void tableInsertNode(CTOMLTable * table, const char * key, CTOMLNode * node) {
		reinterpret_cast<toml::table *>(table)->insert(key, *reinterpret_cast<toml::node *>(node));
	}

	/// Replaces the value at \c key with \c integer .
	void
	tableReplaceOrInsertInt(CTOMLTable * table, const char * key, int64_t integer, uint16_t flags) {
		auto t = reinterpret_cast<toml::table *>(table);
		t->insert_or_assign(key, integer, toml::value_flags(flags));
	}

	/// Replaces the value at \c key with \c tableToInsert .
	void
	tableReplaceOrInsertTable(CTOMLTable * table, const char * key, CTOMLTable * tableToInsert) {
		reinterpret_cast<toml::table *>(table)->insert_or_assign(
			key, *reinterpret_cast<toml::table *>(tableToInsert));
	}

	/// Replaces the value at \c key with \c array .
	void tableReplaceOrInsertArray(CTOMLTable * table, const char * key, CTOMLArray * array) {
		reinterpret_cast<toml::table *>(table)->insert_or_assign(
			key, *reinterpret_cast<toml::array *>(array));
	}

	/// Replaces the value at \c key with \c toml::node .
	void tableReplaceOrInsertNode(CTOMLTable * table, const char * key, CTOMLNode * node) {
		reinterpret_cast<toml::table *>(table)->insert_or_assign(
			key, *reinterpret_cast<toml::node *>(node));
	}

	// MARK: - Table - Data Retrieval

	/// Retrieves a \c toml::node from \c table at \c key .
	CTOMLNode * _Nullable tableGetNode(CTOMLTable * table, const char * key) {
		auto tbl = reinterpret_cast<toml::table *>(table);

		if (tbl->get(key)) { return reinterpret_cast<CTOMLNode *>(tbl->get(key)); }

		return NULL;
	}

	/// Retrieve all the keys from \c table . The size of the return value is the size of \c table .
	const char * const * tableGetKeys(CTOMLTable * table) {
		auto t = reinterpret_cast<toml::table *>(table);
		auto keyArray = (char **) malloc(sizeof(char **) * t->size());
		int64_t index = 0;

		for (auto && [k, v] : *t) {
			keyArray[index] = strdup(std::string(k.str()).c_str());
			index++;
		}

		return keyArray;
	}

	/// Retrieve all the values from \c table . The size of the return value is the size of \c table
	/// .
	CTOMLNode const * const * tableGetValues(CTOMLTable * table) {
		auto t = reinterpret_cast<toml::table *>(table);
		auto valueArray = (CTOMLNode **) malloc(sizeof(CTOMLNode **) * t->size());
		int64_t index = 0;

		for (auto && [k, v] : *t) {
			valueArray[index] = reinterpret_cast<CTOMLNode *>(t->get(k));
			index++;
		}

		return valueArray;
	}

	// MARK: - Table - Data Removal

	/// Remove the element at \c key from \c table .
	void tableRemoveElement(CTOMLTable * table, const char * key) {
		reinterpret_cast<toml::table *>(table)->erase(key);
	}

	// MARK: - Table Conversion

	/// Convert \c table to a TOML document.
	char * tableConvertToTOML(CTOMLTable * table, uint64_t options) {
		std::stringstream ss;

		ss << toml::toml_formatter(
			*reinterpret_cast<toml::table *>(table), toml::format_flags(options));

		return strdup(ss.str().c_str());
	}

	char * tableConvertToJSON(CTOMLTable * table, uint64_t options) {
		std::stringstream ss;

		ss << toml::json_formatter(
			*reinterpret_cast<toml::table *>(table), toml::format_flags(options));

		return strdup(ss.str().c_str());
	}

	/// Convert \c table to a YAML document.
	char * tableConvertToYAML(CTOMLTable * table, uint64_t options) {
		std::stringstream ss;

		ss << toml::yaml_formatter(
			*reinterpret_cast<toml::table *>(table), toml::format_flags(options));

		return strdup(ss.str().c_str());
	}

#ifdef __cplusplus
}
#endif
