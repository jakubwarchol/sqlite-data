#if canImport(CloudKit)
  actor SyncRecoveryGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func hold() async {
      entered = true
      entryWaiter?.resume()
      entryWaiter = nil
      if !released { await withCheckedContinuation { releaseWaiter = $0 } }
    }
    func waitUntilEntered() async {
      if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func release() {
      released = true
      releaseWaiter?.resume()
      releaseWaiter = nil
    }
  }
#endif
