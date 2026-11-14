// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

// Based off of
// https://github.com/jpsim/Yams/blob/074fd3c61d7f50869d074549369eed3b9436061e/Sources/Yams/Encoder.swift#L243-L263
struct TOMLCodingKey: CodingKey {
	var stringValue: String
	var intValue: Int?

	init?(stringValue: String) {
		self.stringValue = stringValue
		self.intValue = nil
	}

	init?(intValue: Int) {
		self.stringValue = "\(intValue)"
		self.intValue = intValue
	}

	init(index: Int) {
		self.stringValue = "Index \(index)"
		self.intValue = index
	}
}
