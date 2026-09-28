import Foundation

@main enum ShortParityEntryCheckMain {
    static func main() throws {
        let input = try JSONDecoder().decode(QwenObservedFixtureInputs.self,
            from: FileHandle.standardInput.readDataToEndOfFile())
        var data = try canonicalJSONData(checkShortParityEntry(input)); data.append(10)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}
