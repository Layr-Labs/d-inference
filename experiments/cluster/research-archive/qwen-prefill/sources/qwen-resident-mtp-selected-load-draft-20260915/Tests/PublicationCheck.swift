import Foundation

enum Failure: Error, Equatable { case load, retire, encode }
func require(_ value: Bool) { precondition(value) }

@main enum PublicationCheck {
    static func main() throws {
        var order: [String] = []
        let result = try QwenResidentMTPLoadPublication.run(body: {
            order.append("body"); return 7
        }, retire: { order.append("retire") }, prepare: {
            require($0 == 7); order.append("encode"); return "CPU"
        })
        require(result == "CPU" && order == ["body", "retire", "encode"])

        for bodyFails in [false, true] {
            for retirementFails in [false, true] {
                if !bodyFails && !retirementFails { continue }
                order = []
                do {
                    let _: String = try QwenResidentMTPLoadPublication.run(body: {
                        order.append("body")
                        if bodyFails { throw Failure.load }
                        return 7
                    }, retire: {
                        order.append("retire")
                        if retirementFails { throw Failure.retire }
                    }, prepare: { _ in order.append("encode"); return "bad" })
                    preconditionFailure("Failed native/retirement path published")
                } catch let value as QwenResidentMTPLoadCleanupError {
                    require(bodyFails && retirementFails)
                    require(value.primary as? Failure == .load && value.cleanup as? Failure == .retire)
                } catch {
                    require(error as? Failure == (bodyFails ? .load : .retire))
                }
                require(order == ["body", "retire"])
            }
        }
        order = []
        do {
            let _: String = try QwenResidentMTPLoadPublication.run(body: {
                order.append("body"); return 7
            }, retire: { order.append("retire") }, prepare: { _ in
                order.append("encode"); throw Failure.encode
            })
            preconditionFailure("Encoding failure reported success")
        } catch { require(error as? Failure == .encode) }
        require(order == ["body", "retire", "encode"])
        print("publication: five groups passed; no native/model execution")
    }
}
