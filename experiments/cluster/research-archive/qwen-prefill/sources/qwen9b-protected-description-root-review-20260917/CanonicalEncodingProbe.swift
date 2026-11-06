import Foundation
let values = ["jaccl/mesh_impl.h":"first", "jaccl/mesh.cpp":"second", "source2":"two", "source10":"ten"]
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
print(String(decoding: try JSONSerialization.data(withJSONObject: values, options:[.sortedKeys,.withoutEscapingSlashes]), as:UTF8.self))
print(String(decoding: try encoder.encode(values), as:UTF8.self))
