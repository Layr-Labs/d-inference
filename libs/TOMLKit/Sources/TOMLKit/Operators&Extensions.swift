// Copyright (c) 2024 Jeff Lebrun
//
//  Licensed under the MIT License.
//
//  The full text of the license can be found in the file named LICENSE.

extension String {
	func leftPadding(to length: Int, with padding: String = "0") -> String {
		guard length > self.count else { return self }
		return String(repeating: padding, count: length - self.count) + self
	}
}

func + <C: Collection, D>(lhs: C, rhs: D) -> [D] where C.Element == D {
	lhs + [rhs]
}
