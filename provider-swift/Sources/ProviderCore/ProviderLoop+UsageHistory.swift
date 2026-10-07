extension ProviderLoop {
    func recordLocalUsage(_ record: ProviderUsageRecord) {
        usageHistory.enqueue(record)
    }
}
