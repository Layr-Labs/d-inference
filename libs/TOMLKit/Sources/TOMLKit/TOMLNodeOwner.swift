#if canImport(Darwin)
	import Darwin.C
#elseif canImport(Glibc)
	import Glibc
#elseif canImport(ucrt)
	import ucrt
#else
	#error("Unsupported Platform")
#endif

import CTOML

/// Owns one C++ node tree the bridge allocated: a table, an array or a value, with every node it holds.
///
/// Every ``TOMLTable``, ``TOMLArray`` and ``TOMLValue`` that refers to a node of the tree holds its owner, so the tree
/// is deleted once, after the last of them is gone. A node inside the tree is never deleted on its own (an edit of its
/// parent that replaces or removes it still deletes it, as toml++ always did).
final class TOMLNodeOwner {
	private let root: OpaquePointer

	/// Takes `root`, which no other owner holds and no table or array contains.
	init(root: OpaquePointer) {
		self.root = root
	}

	deinit {
		nodeDelete(self.root)
	}
}

extension String {
	/// Copies a C string the bridge allocated with `malloc`, then frees it.
	init(freeing cString: UnsafePointer<CChar>) {
		defer { free(UnsafeMutablePointer(mutating: cString)) }
		self.init(cString: cString)
	}
}

extension TOMLValue {
	/// Reads what `copy` copies out of this value's node into a buffer it allocates with `malloc`, then frees the
	/// buffer. The tree stays alive for the read, also when this value is its only reference.
	func readCopy<Copied, Result>(
		_ copy: (OpaquePointer) -> UnsafePointer<Copied>?,
		_ transform: (Copied) -> Result
	) -> Result? {
		withExtendedLifetime(self) {
			guard let copied = copy(self.tomlValuePointer) else { return nil }
			defer { free(UnsafeMutablePointer(mutating: copied)) }
			return transform(copied.pointee)
		}
	}
}
