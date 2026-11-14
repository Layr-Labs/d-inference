// swift-tools-version:5.5

import PackageDescription

let package = Package(
	name: "TOMLKit",
	platforms: [
		.macOS(.v10_15),
		.iOS(.v13),
		.watchOS(.v6),
		.tvOS(.v12),
	],
	products: [
		.library(name: "TOMLKit", targets: ["TOMLKit"]),
	],
	targets: [
		.target(
			name: "CTOML",
			cxxSettings: [
				.define("TOML_EXCEPTIONS", to: "1"),
				.define("_CRT_NONSTDC_NO_WARNINGS", .when(platforms: [.windows])),
			]
		),
		.target(
			name: "TOMLKit",
			dependencies: ["CTOML"]
		),
	],
	cLanguageStandard: .c99,
	cxxLanguageStandard: .cxx17
)
