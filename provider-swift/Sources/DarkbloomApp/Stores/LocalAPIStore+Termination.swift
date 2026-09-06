extension LocalAPIStore {
    /// Await from the parent's async application quit decision. Returning false
    /// means the app must remain open; closing the window must not call this.
    func prepareForApplicationTermination() async -> Bool {
        await localStart.shutdown()
    }
}
