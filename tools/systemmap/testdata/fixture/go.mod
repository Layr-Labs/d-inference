// A miniature service, structured like the coordinator, that the extractor tests
// analyze for real: type-checked by go/packages exactly as the coordinator is, so
// the tests exercise route reading, interface dispatch, SQL classification and
// literal attribution rather than a mock of any of them.
//
// It lives under testdata/ so the go tool ignores it when building the tool.
module svcfix.test

go 1.25.0
