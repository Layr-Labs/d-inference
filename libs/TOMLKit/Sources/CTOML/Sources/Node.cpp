// Copyright (c) 2021 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

#include "Conversion.hpp"
#include "toml.hpp"
#include <CTOML/CTOML.h>
#include <iostream>
#include <string>

#ifdef __cplusplus
extern "C" {
#endif

	/// The TOML type of \c node .
	CTOMLNodeType nodeType(CTOMLNode * node) {
		auto a = reinterpret_cast<toml::node *>(node);
		auto b = a->as<toml::date_time>()->type();

		auto type = reinterpret_cast<toml::node *>(node)->type();

		switch (type) {
			case toml::node_type::array:
				return CTOMLNodeType(array);
				break;
			case toml::node_type::boolean:
				return CTOMLNodeType(boolean);
				break;
			case toml::node_type::date:
				return CTOMLNodeType(date);
				break;
			case toml::node_type::date_time:
				return CTOMLNodeType(dateTime);
				break;
			case toml::node_type::floating_point:
				return CTOMLNodeType(floatingPoint);
				break;
			case toml::node_type::integer:
				return CTOMLNodeType(integer);
				break;
			case toml::node_type::string:
				return CTOMLNodeType(string);
				break;
			case toml::node_type::table:
				return CTOMLNodeType(table);
				break;
			case toml::node_type::time:
				return CTOMLNodeType(timeType);
				break;
			default:
				// FIXME: This shouldn't happen.
				return CTOMLNodeType(string);
		}
	}

	/// Copies \c n and returns the copy.
	CTOMLNode * copyNode(CTOMLNode * n) {
		auto node = reinterpret_cast<toml::node *>(n);
		switch (node->type()) {
			case toml::node_type::array: {
				return reinterpret_cast<CTOMLNode *>(new toml::array(*node->as_array()));
				break;
			}
			case toml::node_type::table: {
				return reinterpret_cast<CTOMLNode *>(new toml::table(*node->as_table()));
				break;
			}
			case toml::node_type::string: {
				return reinterpret_cast<CTOMLNode *>(new toml::value(*node->as_string()));
				break;
			}
			case toml::node_type::integer: {
				return reinterpret_cast<CTOMLNode *>(new toml::value(*node->as_integer()));
				break;
			}
			case toml::node_type::floating_point: {
				return reinterpret_cast<CTOMLNode *>(new toml::value(*node->as_floating_point()));
				break;
			}
			case toml::node_type::boolean: {
				return reinterpret_cast<CTOMLNode *>(new toml::value(*node->as_boolean()));
				break;
			}
			case toml::node_type::date: {
				return reinterpret_cast<CTOMLNode *>(new toml::value(*node->as_date()));
				break;
			}
			case toml::node_type::time: {
				return reinterpret_cast<CTOMLNode *>(new toml::value(*node->as_time()));
				break;
			}
			case toml::node_type::date_time: {
				return reinterpret_cast<CTOMLNode *>(new toml::value(*node->as_date_time()));
				break;
			}
			case toml::node_type::none: {
				// This shouldn't happen.
				return nullptr;
			}
		}
	}

	// MARK: - Creation

	/// Creates a \c CTOMLNode from \c b .
	CTOMLNode * _Nonnull nodeFromBool(bool b) {
		return reinterpret_cast<CTOMLNode *>(new toml::value<bool>(b));
	}

	/// Creates a \c CTOMLNode from \c i .
	CTOMLNode * _Nonnull nodeFromInt(int64_t i) {
		return reinterpret_cast<CTOMLNode *>(new toml::value(i));
	}

	/// Creates a \c CTOMLNode from \c d .
	CTOMLNode * _Nonnull nodeFromDouble(double d) {
		return reinterpret_cast<CTOMLNode *>(new toml::value<double>(d));
	}

	/// Creates a \c CTOMLNode from \c s .
	CTOMLNode * _Nonnull nodeFromString(const char * _Nonnull s) {
		return reinterpret_cast<CTOMLNode *>(new toml::value<std::string>(std::string(s)));
	}

	/// Creates a \c CTOMLNode from \c d .
	CTOMLNode * _Nonnull nodeFromDate(CTOMLDate d) {
		return reinterpret_cast<CTOMLNode *>(new toml::value<toml::date>(cTOMLDateToTomlDate(d)));
	}

	/// Creates a \c CTOMLNode from \c t .
	CTOMLNode * _Nonnull nodeFromTime(CTOMLTime t) {
		return reinterpret_cast<CTOMLNode *>(new toml::value<toml::time>(cTOMLTimeToTomlTime(t)));
	}

	/// Creates a \c CTOMLNode from \c dt .
	CTOMLNode * _Nonnull nodeFromDateTime(CTOMLDateTime dt) {
		return reinterpret_cast<CTOMLNode *>(
			new toml::value<toml::date_time>(cTOMLDateTimeToTomlDateTime(dt)));
	}

	/// Creates a \c CTOMLNode from \c t .
	CTOMLNode * _Nonnull nodeFromTable(CTOMLTable * _Nonnull t) {
		return reinterpret_cast<CTOMLNode *>(reinterpret_cast<toml::table *>(t));
	}

	/// Creates a \c CTOMLNode from \c a .
	CTOMLNode * _Nonnull nodeFromArray(CTOMLTable * _Nonnull a) {
		return reinterpret_cast<CTOMLNode *>(reinterpret_cast<toml::array *>(a));
	}

	// MARK: - Deletion

	/// Deletes \c node with every node it holds.
	void nodeDelete(CTOMLNode * node) { delete reinterpret_cast<toml::node *>(node); }

	/// Frees a \c CTOMLDateTime that \c nodeAsDateTime returned, with its offset.
	void dateTimeFree(const CTOMLDateTime * dateTime) {
		delete dateTime->offset;
		free(const_cast<CTOMLDateTime *>(dateTime));
	}

	// MARK: - Value Retrieval

	/// Retrieves a \c bool from the \c node .
	const bool * _Nullable nodeAsBool(CTOMLNode * _Nonnull node) {
		auto res = reinterpret_cast<toml::node *>(node)->as_boolean();

		if (res == NULL) { return NULL; }

		auto boolMem = (bool *) malloc(sizeof(bool));

		memcpy(boolMem, &res->get(), sizeof(bool));

		return boolMem;
	}

	/// Retrieves a \c int64_t from the \c node .
	const int64_t * _Nullable nodeAsInt(CTOMLNode * _Nonnull node) {
		auto res = reinterpret_cast<toml::node *>(node)->as_integer();

		if (res == NULL) { return NULL; }

		auto intMem = (int64_t *) malloc(sizeof(int64_t));

		memcpy(intMem, &res->get(), sizeof(int64_t));

		return intMem;
	}

	/// Retrieves a \c double from the \c node .
	const double * _Nullable nodeAsDouble(CTOMLNode * _Nonnull node) {
		auto res = reinterpret_cast<toml::node *>(node)->as_floating_point();

		if (res == NULL) { return NULL; }

		auto doubleMem = (double *) malloc(sizeof(double));

		memcpy(doubleMem, &res->get(), sizeof(double));

		return doubleMem;
	}

	/// Retrieves a \c char * from the \c node .
	const char * _Nullable nodeAsString(CTOMLNode * _Nonnull node) {
		auto res = reinterpret_cast<toml::node *>(node)->as_string();

		if (res == NULL) { return NULL; }

		return strdup(res->get().c_str());
	}

	/// Retrieves a \c CTOMLDate from the \c node .
	const CTOMLDate * _Nullable nodeAsDate(CTOMLNode * _Nonnull node) {
		auto res = reinterpret_cast<toml::node *>(node)->as_date();

		if (res == NULL) { return NULL; }

		auto date = res->get();

		auto dateMem = (CTOMLDate *) malloc(sizeof(CTOMLDate));

		CTOMLDate cTOMLDate = tomlDateToCTOMLDate(date);

		memcpy(dateMem, &cTOMLDate, sizeof(CTOMLDate));

		return dateMem;
	}

	/// Retrieves a \c CTOMLTime from the \c node .
	const CTOMLTime * _Nullable nodeAsTime(CTOMLNode * _Nonnull node) {
		auto res = reinterpret_cast<toml::node *>(node)->as_time();

		if (res == NULL) { return NULL; }

		auto time = res->get();

		auto timeMem = (CTOMLTime *) malloc(sizeof(CTOMLTime));

		CTOMLTime cTOMLTime = tomlTimeToCTOMLTime(time);

		memcpy(timeMem, &cTOMLTime, sizeof(CTOMLTime));

		return timeMem;
	}

	/// Retrieves a \c CTOMLDateTime from the \c node .
	const CTOMLDateTime * _Nullable nodeAsDateTime(CTOMLNode * _Nonnull node) {
		auto res = reinterpret_cast<toml::node *>(node)->as_date_time();

		if (res == NULL) { return NULL; }

		auto dateTime = res->get();

		auto dateTimeMem = (CTOMLDateTime *) malloc(sizeof(CTOMLDateTime));

		CTOMLDateTime cTOMLDateTime = tomlDateTimeToCTOMLDateTime(dateTime);

		memcpy(dateTimeMem, &cTOMLDateTime, sizeof(CTOMLDateTime));

		return dateTimeMem;
	}

	/// Retrieves a \c CTOMLTable from the \c node .
	CTOMLTable * _Nullable nodeAsTable(CTOMLNode * _Nonnull node) {
		auto res = reinterpret_cast<toml::node *>(node)->as_table();

		if (res == NULL) { return NULL; }

		return reinterpret_cast<CTOMLTable *>(res);
	}

	/// Retrieves a \c CTOMLArray from the \c node .
	CTOMLArray * _Nullable nodeAsArray(CTOMLNode * _Nonnull node) {
		auto res = reinterpret_cast<toml::node *>(node)->as_array();

		if (res == NULL) { return NULL; }

		return reinterpret_cast<CTOMLArray *>(res);
	}

#ifdef __cplusplus
}
#endif
