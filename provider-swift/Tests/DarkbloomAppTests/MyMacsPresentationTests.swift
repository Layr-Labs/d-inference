import Testing
@testable import DarkbloomApp

@Test("My Macs keeps a visible selection and falls back only when it leaves the inventory")
@MainActor
func myMacsSelectionReconcilesVisibleOpaqueIDs() throws {
    let macs = MyMacsStore(fixture: .ready).macs
    let offline = try #require(macs.first { $0.lifecycle == .offline })
    let serving = try #require(macs.first { $0.lifecycle == .serving })

    #expect(MyMacsPresentation.defaultSelection(in: macs) == serving.id)
    #expect(MyMacsPresentation.reconciledSelection(offline.id, in: macs) == offline.id)
    #expect(MyMacsPresentation.reconciledSelection(offline.id, in: [serving]) == serving.id)
    #expect(MyMacsPresentation.reconciledSelection(offline.id, in: []) == nil)
    #expect(MyMacsPresentation.reconciledSelection("removed-record", in: macs) == serving.id)
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

@Test("Duplicate Mac names use deterministic ordinals without hardware identifiers")
@MainActor
func myMacsTitlesPreserveHierarchyAndIdentifierPrivacy() throws {
    let macs = MyMacsStore(fixture: .ready).macs
    let macBook = try #require(macs.first { $0.lifecycle == .serving })
    let studios = macs.filter { $0.hardware?.machineModel == "Mac Studio" }

    #expect(MyMacsPresentation.title(for: macBook, in: macs) == "MacBook Pro")
    #expect(MyMacsPresentation.supportLine(for: macBook).hasPrefix("Apple M4 Max"))
    #expect(!MyMacsPresentation.supportLine(for: macBook).contains("MacBook Pro"))
    #expect(studios.count == 2)
    #expect(Set(studios.map { MyMacsPresentation.title(for: $0, in: macs) }) == [
        "Mac Studio · 1", "Mac Studio · 2",
    ])
    for studio in studios {
        let title = MyMacsPresentation.title(for: studio, in: macs)
        #expect(title == MyMacsPresentation.title(for: studio, in: Array(macs.reversed())))
        #expect(!title.contains(studio.providerID))
    }
    let secondStudio = MyMacsPresentation.filtered(
        macs, searchText: "Mac Studio · 2", status: .all, attention: .all
    )
    #expect(secondStudio.count == 1)
    for query in ["H2YVQ0STUDIO", "H2YUNTRUSTED", "Q6L4"] {
        #expect(MyMacsPresentation.filtered(
            macs, searchText: query, status: .all, attention: .all
        ).isEmpty)
    }
}

@Test("My Macs and Local API suppress network lifecycle toolbar controls")
func productDestinationLifecycleControlScopeIsExplicit() {
    #expect(ProductDestination.myMacs.hidesProviderLifecycleControls)
    #expect(ProductDestination.localAPI.hidesProviderLifecycleControls)
    #expect(!ProductDestination.overview.hidesProviderLifecycleControls)
}
