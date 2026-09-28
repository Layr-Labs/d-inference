# Match native JACCL device-name bounds

The frozen Stage 1 configuration accepted device names up to 64 bytes; actual native QwenResidentJACCLConfiguration.parseMatrix accepts at most 63. A 64-byte saved name would later refuse before loading, not gain readiness. This correction changes only the configuration bound and adds a 63-byte accepted/64-byte rejected fixture using the real complete codec. Frozen a51b1116 and its passing evidence are preserved. Root owns promotion after its current Provider compile completes.

Copy ClusterConfiguration.swift to the same ProviderCore Config path or apply runtime.patch. ConfigurationCheck.swift replaces only the private standalone fixture in a new test run; fixture.patch shows the exact delta. No main/Protocol/native change was made by the author. The existing native parser remains the authority.
