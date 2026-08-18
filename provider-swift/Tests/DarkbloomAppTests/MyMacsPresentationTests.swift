import Testing
@testable import DarkbloomApp

@Test("My Macs selects an exact local serial before connection fallbacks")
@MainActor
func myMacsDefaultSelectionUsesExactSerial() throws {
    let macs = MyMacsStore(fixture: .ready).macs
    let offline = try #require(macs.first { $0.lifecycle == .offline })
    let serving = try #require(macs.first { $0.lifecycle == .serving })

    #expect(MyMacsPresentation.defaultSelection(
        in: macs,
        currentSerialNumber: offline.serialNumber
    ) == offline.id)
    #expect(MyMacsPresentation.defaultSelection(
        in: macs,
        currentSerialNumber: "MINI2025"
    ) == serving.id)
    #expect(MyMacsPresentation.isThisMac(
        offline,
        currentSerialNumber: "MINI2025"
    ) == false)
}

@Test("My Macs filters search raw reported model IDs and coordinator attention")
@MainActor
func myMacsFiltersAreTruthful() throws {
    let macs = MyMacsStore(fixture: .ready).macs

    let gemma = MyMacsPresentation.filtered(
        macs,
        searchText: "gemma-4-26b",
        status: .all,
        attention: .all
    )
    #expect(gemma.count == 1)
    #expect(gemma.first?.lifecycle == .online)

    let connected = MyMacsPresentation.filtered(
        macs,
        searchText: "",
        status: .connected,
        attention: .all
    )
    #expect(Set(connected.map(\.lifecycle)) == Set([.serving, .online]))

    let attention = MyMacsPresentation.filtered(
        macs,
        searchText: "",
        status: .all,
        attention: .needsAttention
    )
    #expect(!attention.isEmpty)
    #expect(attention.allSatisfy { $0.attention.requiresAttention })
}

@Test("My Macs titles lead with machine model and disambiguate only duplicate models")
@MainActor
func myMacsTitlesPreserveHierarchyAndSerialPrivacy() throws {
    let macs = MyMacsStore(fixture: .ready).macs
    let macBook = try #require(macs.first { $0.lifecycle == .serving })
    let studios = macs.filter { $0.hardware?.machineModel == "Mac Studio" }

    #expect(MyMacsPresentation.title(for: macBook, in: macs) == "MacBook Pro")
    #expect(!MyMacsPresentation.title(for: macBook, in: macs).contains("••••"))
    #expect(MyMacsPresentation.supportLine(for: macBook).hasPrefix("Apple M4 Max"))
    #expect(!MyMacsPresentation.supportLine(for: macBook).contains("MacBook Pro"))
    #expect(MyMacsPresentation.inventorySupportLine(for: macBook) == "Apple M4 Max")

    #expect(studios.count == 2)
    for studio in studios {
        let title = MyMacsPresentation.title(for: studio, in: macs)
        #expect(title.hasPrefix("Mac Studio · •••• "))
        #expect(!title.contains(studio.serialNumber ?? "serial-not-reported"))

        let compactTitle = MyMacsPresentation.bloomlineTitle(for: studio, in: macs)
        #expect(compactTitle.hasPrefix("Mac Studio · #"))
        #expect(!compactTitle.contains("•"))
        #expect(compactTitle.hasSuffix(String(try #require(studio.serialNumber).suffix(4))))
    }
}

#if DEBUG
@Test("My Macs product preview resolves a deterministic fixture-aligned This Mac")
@MainActor
func myMacsPreviewIdentityMatchesInventoryFixture() throws {
    let identity = try #require(SystemProfilerMachineIdentityProvider.previewIdentity(
        environment: ["DARKBLOOM_PREVIEW_PRODUCT_DESTINATION": "my-macs"]
    ))
    let macs = MyMacsStore(fixture: .ready).macs
    let thisMac = try #require(macs.first {
        MyMacsPresentation.isThisMac($0, currentSerialNumber: identity.serialNumber)
    })

    #expect(identity.serialNumber == "FVFGH0STQ6L4")
    #expect(thisMac.lifecycle == .serving)
    #expect(MyMacsPresentation.title(for: thisMac) == "MacBook Pro")
}
#endif

@Test("My Macs and Local API suppress network lifecycle toolbar controls")
func productDestinationLifecycleControlScopeIsExplicit() {
    #expect(ProductDestination.myMacs.hidesProviderLifecycleControls)
    #expect(ProductDestination.localAPI.hidesProviderLifecycleControls)
    #expect(!ProductDestination.overview.hidesProviderLifecycleControls)
}
