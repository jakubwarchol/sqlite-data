#if canImport(CloudKit)
  public import CloudKit
  package import ConcurrencyExtras
  import Dependencies
  public import GRDB
  public import IssueReporting
  import OrderedCollections
  public import OSLog
  import Observation
  public import StructuredQueries
  import StructuredQueriesSQLite
  #if EXCLUDE_EXPORTS
    public import StructuredQueriesSQLiteCore
  #endif
  import SwiftData
  import TabularData

  #if canImport(UIKit)
    import UIKit
  #endif

  /// An object that manages the synchronization of local and remote SQLite data.
  ///
  /// See <doc:CloudKitSync> for more information.
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  public final class SyncEngine: Observable, Sendable {
    package let userDatabase: UserDatabase
    package let logger: Logger
    let diagnosticEmitter: SyncDiagnosticEmitter?
    package let metadatabase: any DatabaseWriter
    package let tables: [any SynchronizableTable]
    package let privateTables: [any SynchronizableTable]
    let tablesByName: [String: any SynchronizableTable]
    package let tablesByOrder: [String: Int]
    let foreignKeysByTableName: [String: [ForeignKey]]
    package let syncEngines = LockIsolated<SyncEngines>(SyncEngines())
    package let defaultZone: CKRecordZone
    let delegate: (any SyncEngineDelegate)?
    let defaultSyncEngines:
      @Sendable (any DatabaseReader, SyncEngine)
        throws -> (private: any SyncEngineProtocol, shared: any SyncEngineProtocol)
    package let container: any CloudContainer
    let dataManager = Dependency(\.dataManager)
    let observationRegistrar = ObservationRegistrar()
    private let notificationsObserver = LockIsolated<(any NSObjectProtocol)?>(nil)
    private let activityCounts = LockIsolated(ActivityCounts())
    let startTask = LockIsolated<Task<Void, any Error>?>(nil)
    let workTracker = SyncWorkTracker()
    let startStopLock = NSRecursiveLock()
    let isDraining = LockIsolated(false)
    let isResetting = LockIsolated(false)
    let retirementTask = LockIsolated<Task<Void, Never>?>(nil)
    let startupTask = LockIsolated<Task<SyncWorkTracker.Token, any Error>?>(nil)
    let startup = LockIsolated<StartupState>(.stopped)
    let accountIsolation: SyncAccountIsolation?
    let accountAdoptionID = UUID()
    let authorizedAccount = LockIsolated<String?>(nil)
    let pendingAccountAdoption = LockIsolated<String?>(nil)
    let accountFailure = LockIsolated<SyncAccountIsolationError?>(nil)
    let fetchCompletion = LockIsolated(FetchCompletionState())
    let incomingReplayGate = IncomingReplayGate()
    let incomingCheckpointBlocked = LockIsolated<Set<CKDatabase.Scope>>([])
    #if DEBUG && canImport(DeveloperToolsSupport)
      private let previewTimerTask = LockIsolated<Task<Void, Never>?>(nil)
    #endif

    /// The error message used when a write occurs to a record for which the current user does not
    /// have permission.
    ///
    /// This error is thrown from any database write to a row for which the current user does
    /// not have permissions to write, as determined by its `CKShare` (if applicable). To catch
    /// this error try casting it to `DatabaseError` and checking its message:
    ///
    /// ```swift
    /// do {
    ///   try await database.write { db in
    ///     Reminder.find(id)
    ///       .update { $0.title = "Personal" }
    ///       .execute(db)
    ///   }
    /// } catch let error as DatabaseError where error.message == SyncEngine.writePermissionError {
    ///   // User does not have permission to write to this record.
    /// }
    /// ```
    public static let writePermissionError =
      "co.pointfree.SQLiteData.CloudKit.write-permission-error"
    public static let invalidRecordNameError =
      "co.pointfree.SQLiteData.CloudKit.invalid-record-name-error"

    /// Initialize a sync engine.
    ///
    /// - Parameters:
    ///   - database: The database to synchronize to CloudKit.
    ///   - tables: A list of tables that you want to synchronize _and_ that you want to be
    ///     shareable with other users on CloudKit.
    ///   - privateTables: A list of tables that you want to synchronize to CloudKit but that
    ///     you do not want to be shareable with other users.
    ///   - containerIdentifier: The container identifier in CloudKit to synchronize to. If omitted
    ///     the container will be determined from the entitlements of your app.
    ///   - defaultZone: The zone for all records to be stored in.
    ///   - startImmediately: Determines if the sync engine starts right away or requires an
    ///     explicit call to ``start()``. By default this argument is `true`.
    ///   - delegate: A delegate object that can be notified of events and override default sync
    ///     engine behavior.
    ///   - logger: Apple logger for existing debug output. Disabled in tests by default.
    ///   - diagnostics: Optional structured diagnostics, also emitted in release builds.
    public convenience init<
      each T1: PrimaryKeyedTable & _SendableMetatype,
      each T2: PrimaryKeyedTable & _SendableMetatype
    >(
      for database: any DatabaseWriter,
      tables: repeat (each T1).Type,
      privateTables: repeat (each T2).Type,
      containerIdentifier: String? = nil,
      defaultZone: CKRecordZone = CKRecordZone(zoneName: "co.pointfree.SQLiteData.defaultZone"),
      startImmediately: Bool? = nil,
      delegate: (any SyncEngineDelegate)? = nil,
      logger: Logger = isTesting
        ? Logger(.disabled) : Logger(subsystem: "SQLiteData", category: "CloudKit"),
      diagnostics: SyncDiagnostics? = nil,
      accountIsolation: SyncAccountIsolation? = nil
    ) throws
    where
      repeat (each T1).PrimaryKey.QueryOutput: IdentifierStringConvertible,
      repeat (each T1).TableColumns.PrimaryColumn: WritableTableColumnExpression,
      repeat (each T2).PrimaryKey.QueryOutput: IdentifierStringConvertible,
      repeat (each T2).TableColumns.PrimaryColumn: WritableTableColumnExpression
    {
      @Dependency(\.context) var context
      let containerIdentifier =
        containerIdentifier
        ?? ModelConfiguration(groupContainer: .automatic).cloudKitContainerIdentifier
        ?? (context != .live ? "container" : nil)
      var allTables: [any SynchronizableTable] = []
      var allPrivateTables: [any SynchronizableTable] = []
      for table in repeat each tables {
        allTables.append(SynchronizedTable(for: table))
      }
      for privateTable in repeat each privateTables {
        allPrivateTables.append(SynchronizedTable(for: privateTable))
      }
      let userDatabase = UserDatabase(database: database)

      guard context == .live
      else {
        let privateDatabase = MockCloudDatabase(databaseScope: .private)
        let sharedDatabase = MockCloudDatabase(databaseScope: .shared)
        let container = MockCloudContainer(
          containerIdentifier: containerIdentifier ?? "iCloud.co.pointfree.SQLiteData.Tests",
          privateCloudDatabase: privateDatabase,
          sharedCloudDatabase: sharedDatabase
        )
        privateDatabase.set(container: container)
        sharedDatabase.set(container: container)
        try self.init(
          container: container,
          defaultZone: defaultZone,
          defaultSyncEngines: { database, syncEngine in
            (
              private: MockSyncEngine(
                database: privateDatabase,
                parentSyncEngine: syncEngine,
                state: try syncEngine.restoredMockState(in: database, scope: .private)
              ),
              shared: MockSyncEngine(
                database: sharedDatabase,
                parentSyncEngine: syncEngine,
                state: try syncEngine.restoredMockState(in: database, scope: .shared)
              )
            )
          },
          userDatabase: userDatabase,
          logger: logger,
          delegate: delegate,
          tables: allTables,
          privateTables: allPrivateTables,
          diagnostics: diagnostics,
          accountIsolation: accountIsolation
        )
        try setUpSyncEngine()
        if startImmediately ?? !isTesting {
          _ = try requestStart()
        }
        return
      }

      guard let containerIdentifier else {
        throw SchemaError.noCloudKitContainer
      }

      let container = CKContainer(identifier: containerIdentifier)
      try self.init(
        container: container,
        defaultZone: defaultZone,
        defaultSyncEngines: { database, syncEngine in
          let privateState = try syncEngine.diagnosticStateSerialization(in: database, scope: .private)
          let sharedState = try syncEngine.diagnosticStateSerialization(in: database, scope: .shared)
          return (
            private: CKSyncEngine(
              CKSyncEngine.Configuration(
                database: container.privateCloudDatabase,
                stateSerialization: privateState,
                delegate: SyncSessionDelegate(owner: syncEngine)
              )
            ),
            shared: CKSyncEngine(
              CKSyncEngine.Configuration(
                database: container.sharedCloudDatabase,
                stateSerialization: sharedState,
                delegate: SyncSessionDelegate(owner: syncEngine)
              )
            )
          )
        },
        userDatabase: userDatabase,
        logger: logger,
        delegate: delegate,
        tables: allTables,
        privateTables: allPrivateTables,
        diagnostics: diagnostics,
        accountIsolation: accountIsolation
      )
      try setUpSyncEngine()
      if startImmediately ?? !isTesting {
        _ = try requestStart()
      }
    }

    package init(
      container: any CloudContainer,
      defaultZone: CKRecordZone,
      defaultSyncEngines:
        @escaping @Sendable (
          any DatabaseReader,
          SyncEngine
        ) throws -> (private: any SyncEngineProtocol, shared: any SyncEngineProtocol),
      userDatabase: UserDatabase,
      logger: Logger,
      delegate: (any SyncEngineDelegate)?,
      tables: [any SynchronizableTable],
      privateTables: [any SynchronizableTable] = [],
      diagnostics: SyncDiagnostics? = nil,
      accountIsolation: SyncAccountIsolation? = nil
    ) throws {
      let allTables = OrderedSet((tables + privateTables).map(HashableSynchronizedTable.init))
        .map(\.type)
      self.tables = allTables
      self.privateTables = privateTables
      self.delegate = delegate
      self.accountIsolation = accountIsolation
      self.diagnosticEmitter = diagnostics.map(SyncDiagnosticEmitter.init)

      let foreignKeysByTableName = Dictionary(
        uniqueKeysWithValues: try userDatabase.read { db in
          try allTables.map { table -> (String, [ForeignKey]) in
            func open<T>(
              _: some SynchronizableTable<T>
            ) throws -> (String, [ForeignKey]) {
              (
                T.tableName,
                try PragmaForeignKeyList<T>
                  .join(PragmaTableInfo<T>.all) { $0.from.eq($1.name) }
                  .select {
                    ForeignKey.Columns(
                      table: $0.table,
                      from: $0.from,
                      to: $0.to,
                      onUpdate: $0.onUpdate,
                      onDelete: $0.onDelete,
                      isNotNull: $1.isNotNull
                    )
                  }
                  .fetchAll(db)
              )
            }
            return try open(table)
          }
        }
      )
      self.container = container
      self.defaultZone = defaultZone
      self.defaultSyncEngines = defaultSyncEngines
      self.userDatabase = userDatabase
      self.logger = logger
      self.metadatabase = try defaultMetadatabase(
        logger: logger,
        url: try URL.metadatabase(
          databasePath: userDatabase.path,
          containerIdentifier: container.containerIdentifier
        ),
        configuration: userDatabase.configuration
      )
      self.tablesByName = Dictionary(
        uniqueKeysWithValues: self.tables.map { ($0.base.tableName, $0) }
      )
      self.foreignKeysByTableName = foreignKeysByTableName
      tablesByOrder = try SQLiteData.tablesByOrder(
        userDatabase: userDatabase,
        tables: allTables,
        tablesByName: tablesByName
      )
      #if os(iOS)
        @Dependency(\.defaultNotificationCenter) var defaultNotificationCenter
        notificationsObserver.withValue {
          $0 = defaultNotificationCenter.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: nil
          ) { [weak self] _ in
            _ = Task { @MainActor [weak self] in
              let taskIdentifier = UIApplication.shared.beginBackgroundTask()
              defer { UIApplication.shared.endBackgroundTask(taskIdentifier) }
              try await self?.sendChanges()
            }
          }
        }
      #endif
      try validateSchema()
    }

    deinit {
      notificationsObserver.withValue {
        guard let observer = $0
        else { return }
        NotificationCenter.default.removeObserver(observer)
      }
    }

    let outgoingAttempts = OutgoingAttempts()
    let outgoingReady = LockIsolated(false)

    nonisolated package func setUpSyncEngine() throws {
      try userDatabase.write { db in
        try setUpSyncEngine(writableDB: db)
      }
    }

    nonisolated package func setUpSyncEngine(writableDB db: Database) throws {
      let attachedMetadatabasePath: String? =
        try PragmaDatabaseList
        .where { $0.name.eq(String.sqliteDataCloudKitSchemaName) }
        .select(\.file)
        .fetchOne(db)
      if let attachedMetadatabasePath {
        let metadatabaseName =
          metadatabase.path.isEmpty
          ? try URL.metadatabase(
            databasePath: "",
            containerIdentifier: self.container.containerIdentifier
          )
          .lastPathComponent
          : URL(filePath: metadatabase.path).lastPathComponent
        let attachedMetadatabaseName =
          URL(string: attachedMetadatabasePath)?.lastPathComponent ?? ""
        @Dependency(\.context) var context
        if metadatabaseName != attachedMetadatabaseName
          && !(context == .preview && attachedMetadatabaseName.isEmpty)
        {
          throw SchemaError(
            reason: .metadatabaseMismatch(
              attachedPath: attachedMetadatabasePath,
              syncEngineConfiguredPath: metadatabase.path
            ),
            debugDescription: """
              Metadatabase attached in 'prepareDatabase' does not match metadatabase prepared in \
              'SyncEngine.init'. Are different CloudKit container identifiers being provided?
              """
          )
        }
      } else {
        try #sql(
          """
          ATTACH DATABASE \(bind: metadatabase.path) AS \(quote: .sqliteDataCloudKitSchemaName)
          """
        )
        .execute(db)
      }
      db.add(function: $currentTime)
      db.add(function: SyncEngine.$isSynchronizing)
      db.add(function: $didUpdate)
      db.add(function: $didDelete)
      db.add(function: $hasPermission)
      db.add(function: $currentZoneName)
      db.add(function: $currentOwnerName)

      try prepareOutgoingIntents(in: db)
      try IncomingJournal.create(in: db)
      if accountIsolation != nil { try SyncAccountBinding.create(db) }
      else if try db.tableExists(SyncAccountBinding.table),
        try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM main.\(SyncAccountBinding.table))") == true {
        throw SyncAccountIsolationError.configurationRequired
      }

      for trigger in SyncMetadata.callbackTriggers(for: self) {
        try trigger.execute(db)
      }

      for table in tables {
        try table.base.createTriggers(
          foreignKeysByTableName: foreignKeysByTableName,
          tablesByName: tablesByName,
          defaultZone: defaultZone,
          privateTables: privateTables,
          db: db
        )
      }
    }

    /// Determines if the sync engine is currently sending local changes to the CloudKit server.
    ///
    /// It is an observable value, which means if it is accessed in a SwiftUI view, or some other
    /// observable context, then the view will automatically re-render when the value changes. As
    /// such, it can be useful for displaying a progress view to indicate that work is currently
    /// being done to synchronize changes.
    public var isSendingChanges: Bool {
      sendingChangesCount > 0
    }

    /// Determines if the sync engine is currently processing changes being sent to the device
    /// from CloudKit.
    ///
    /// It is an observable value, which means if it is accessed in a SwiftUI view, or some other
    /// observable context, then the view will automatically re-render when the value changes. As
    /// such, it can be useful for displaying a progress view to indicate that work is currently
    /// being done to synchronize changes.
    public var isFetchingChanges: Bool {
      fetchingChangesCount > 0
    }

    /// Determines if the sync engine is currently sending or receiving changes from CloudKit.
    ///
    /// This value is true if either of ``isSendingChanges`` or ``isFetchingChanges`` is true.
    /// It is an observable value, which means if it is accessed in a SwiftUI view, or some other
    /// observable context, then the view will automatically re-render when the value changes. As
    /// such, it can be useful for displaying a progress view to indicate that work is currently
    /// being done to synchronize changes.
    public var isSynchronizing: Bool {
      isSendingChanges || isFetchingChanges
    }

    /// Stops the sync engine if it is running.
    ///
    /// All edits made after stopping the sync engine will not be synchronized to CloudKit.
    /// You must start the sync engine again using ``start()`` to synchronize the changes.
    public func stop() {
      let context = diagnosticEmitter.map { _ in makeDiagnosticOperation(stage: .stopRequested) }
      emitDiagnostic(.stopRequested, operation: context)
      defer { emitDiagnostic(.stopReturned, operation: context, outcome: .callbackCompleted, finished: true) }
      startStopLock.withLock {
        guard !isDraining.value else { return }
        isDraining.withValue { $0 = true }
        #if DEBUG && canImport(DeveloperToolsSupport)
          previewTimerTask.withValue { $0?.cancel(); $0 = nil }
        #endif
        startupTask.withValue { $0?.cancel(); $0 = nil }
        setStartupState(.stopped)
        let retired = syncEngines.value
        workTracker.retire()
        observationRegistrar.withMutation(of: self, keyPath: \.isRunning) {
          syncEngines.withValue {
            outgoingAttempts.clear()
            outgoingReady.withValue { $0 = false }
            $0 = SyncEngines()
          }
        }
        fetchingChangesCount = 0
        sendingChangesCount = 0
        retire(retired)
      }
    }

    /// Whether the underlying transports are allocated, including during preparation.
    /// Use `startupState`, `isPrepared`, or await `start()` for preparation success.
    public var isRunning: Bool {
      observationRegistrar.access(self, keyPath: \.isRunning)
      return syncEngines.withValue {
        $0.isRunning
      }
    }

    func prepareStart() throws -> Task<Void, any Error> {
      outgoingReady.withValue { $0 = false }
      try observationRegistrar.withMutation(of: self, keyPath: \.isRunning) {
        try syncEngines.withValue {
          let (privateSyncEngine, sharedSyncEngine) = try defaultSyncEngines(userDatabase.database, self)
          $0 = SyncEngines(
            private: privateSyncEngine,
            shared: sharedSyncEngine
          )
        }
      }

      try adoptSerializedOutgoingIntents()
      outgoingReady.withValue { $0 = true }

      let previousRecordTypes = try metadatabase.read { db in
        try RecordType.all.fetchAll(db)
      }
      let currentRecordTypes = try userDatabase.read { db in
        let namesAndSchemas =
          try SQLiteSchema
          .where {
            $0.type.eq(#bind(.table))
              && $0.tableName.in(tables.map { $0.base.tableName })
          }
          .fetchAll(db)
        return try namesAndSchemas.compactMap { schema -> RecordType? in
          guard let sql = schema.sql, let table = tablesByName[schema.name]
          else { return nil }
          func open<T>(_: some SynchronizableTable<T>) throws -> RecordType {
            try RecordType(
              tableName: schema.name,
              schema: sql,
              tableInfo: Set(
                PragmaTableInfo<T>
                  .select {
                    TableInfo.Columns(
                      defaultValue: $0.defaultValue,
                      isPrimaryKey: $0.isPrimaryKey,
                      name: $0.name,
                      isNotNull: $0.isNotNull,
                      type: $0.type
                    )
                  }
                  .fetchAll(db)
              )
            )
          }
          return try open(table)
        }
      }
      let previousRecordTypeByTableName = Dictionary(
        uniqueKeysWithValues: previousRecordTypes.map {
          ($0.tableName, $0)
        }
      )
      let currentRecordTypeByTableName = Dictionary(
        uniqueKeysWithValues: currentRecordTypes.map {
          ($0.tableName, $0)
        }
      )

      #if DEBUG && canImport(DeveloperToolsSupport)
        @Dependency(\.context) var context
        @Dependency(\.continuousClock) var clock
        if context == .preview {
          previewTimerTask.withValue {
            $0?.cancel()
            $0 = Task { @Sendable [weak self] in
              await withErrorReporting {
                while true {
                  guard let self else { break }
                  try await clock.sleep(for: .seconds(1))
                  try await self.syncChanges()
                }
              }
            }
          }
        }
      #endif
      let startupLease = try workTracker.begin(expected: SyncWorkContext.token)
      let startTask = Task<Void, any Error> {
        defer { startupLease.finish() }
        try SyncWorkContext.token?.check()
        let status = try await container.accountStatus()
        guard status == .available else { throw StartupError.accountUnavailable(status) }
        try SyncWorkContext.token?.check()
        syncEngines.withValue {
          $0.private?.state.add(pendingDatabaseChanges: [.saveZone(defaultZone)])
        }
        try await uploadRecordsToCloudKit(
          previousRecordTypeByTableName: previousRecordTypeByTableName,
          currentRecordTypeByTableName: currentRecordTypeByTableName
        )
        try await updateLocalFromSchemaChange(
          previousRecordTypeByTableName: previousRecordTypeByTableName,
          currentRecordTypeByTableName: currentRecordTypeByTableName
        )
        try await cacheUserTables(recordTypes: currentRecordTypes)
        // Retained downloads have their own checked-fetch/recovery contract. Their
        // failure does not prevent starting the transport needed to recover them.
        await replayIncomingChanges()
        try SyncWorkContext.token?.check()
      }
      self.startTask.withValue {
        $0?.cancel()
        $0 = startTask
      }
      return startTask
    }

    /// Fetches pending remote changes from the server.
    ///
    /// Use this method to ensure the sync engine immediately fetches all pending remote changes
    /// before your app continues. This isn't necessary in normal use, as the engine automatically
    /// syncs your app's records. It is useful, however, in scenarios where you require more control
    /// over sync, such as pull-to-refresh.
    ///
    /// - Parameter options: The options to use when fetching changes.
    public func fetchChanges(
      _ options: CKSyncEngine.FetchChangesOptions = CKSyncEngine.FetchChangesOptions()
    ) async throws {
      try await withSyncWork {
        try await diagnoseRequest(.fetchRequested) {
          try await requireAccountOwnership()
          try await fetchChangesImpl(options)
        }
      }
    }

    private func fetchChangesImpl(_ options: CKSyncEngine.FetchChangesOptions) async throws {
      try await startupTask.value?.value.check()
      let (privateSyncEngine, sharedSyncEngine) = syncEngines.withValue {
        ($0.private, $0.shared)
      }
      guard let privateSyncEngine, let sharedSyncEngine
      else { return }
      async let `private`: Void = privateSyncEngine.fetchChanges(options)
      async let shared: Void = sharedSyncEngine.fetchChanges(options)
      _ = try await (`private`, shared)
    }

    /// Sends pending local changes to the server.
    ///
    /// Use this method to ensure the sync engine sends all pending local changes to the server
    /// before your app continues. This isn't necessary in normal use, as the engine automatically
    /// syncs your app's records. It is useful, however, in scenarios where you require greater
    /// control over sync, such as a "Backup now" button.
    ///
    /// - Parameter options: The options to use when sending changes.
    public func sendChanges(
      _ options: CKSyncEngine.SendChangesOptions = CKSyncEngine.SendChangesOptions()
    ) async throws {
      try await withSyncWork {
        try await diagnoseRequest(.sendRequested) {
          try await requireAccountOwnership()
          try await sendChangesImpl(options)
        }
      }
    }

    private func sendChangesImpl(_ options: CKSyncEngine.SendChangesOptions) async throws {
      try await startupTask.value?.value.check()
      let (privateSyncEngine, sharedSyncEngine) = syncEngines.withValue {
        ($0.private, $0.shared)
      }
      guard let privateSyncEngine, let sharedSyncEngine
      else { return }
      async let `private`: Void = privateSyncEngine.sendChanges(options)
      async let shared: Void = sharedSyncEngine.sendChanges(options)
      _ = try await (`private`, shared)
    }

    /// Synchronizes local and remote pending changes.
    ///
    /// Use this method to ensure the sync engine immediately fetches all pending remote changes
    /// _and_ sends all pending local changes to the server. This isn't necessary in normal use,
    /// as the engine automatically syncs your app's records. It is useful, however, in scenarios
    /// where you require greater control over sync.
    ///
    /// - Parameters:
    ///   - fetchOptions: The options to use when fetching changes.
    ///   - sendOptions: The options to use when sending changes.
    public func syncChanges(
      fetchOptions: CKSyncEngine.FetchChangesOptions = CKSyncEngine.FetchChangesOptions(),
      sendOptions: CKSyncEngine.SendChangesOptions = CKSyncEngine.SendChangesOptions()
    ) async throws {
      try await withSyncWork {
        try await sendChanges(sendOptions)
        try await fetchChanges(fetchOptions)
      }
    }

    private func cacheUserTables(recordTypes: [RecordType]) async throws {
      try await userDatabase.write { db in
        try RecordType
          .upsert { recordTypes.map { RecordType.Draft($0) } }
          .execute(db)
      }
    }

    private func uploadRecordsToCloudKit(
      previousRecordTypeByTableName: [String: RecordType],
      currentRecordTypeByTableName: [String: RecordType]
    ) async throws {
      try await enqueueLocallyPendingChanges()
      try await userDatabase.write { db in
        let newTableNames = currentRecordTypeByTableName.keys.filter { tableName in
          previousRecordTypeByTableName[tableName] == nil
        }

        try $_isSynchronizingChanges.withValue(false) {
          for tableName in newTableNames {
            try self.uploadRecordsToCloudKit(tableName: tableName, db: db)
          }
        }
      }
    }

    private func enqueueLocallyPendingChanges() async throws {
      try await enqueueOutgoingIntents()
    }

    private func enqueueUnknownRecordsForCloudKit() async throws {
      try await userDatabase.write { db in
        try $_isSynchronizingChanges.withValue(false) {
          try SyncMetadata
            .where { !$0.hasLastKnownServerRecord }
            .update { $0.recordPrimaryKey = $0.recordPrimaryKey }
            .execute(db)
        }
      }
    }

    private func uploadRecordsToCloudKit<T>(
      table: some SynchronizableTable<T>,
      db: Database
    ) throws {
      // try T.update { $0.primaryKey = $0.primaryKey }.execute(db)
      try #sql(
        """
        UPDATE \(T.self) SET \(quote: T.primaryKey.name) = \(quote: T.primaryKey.name)
        """
      )
      .execute(db)
    }

    private func uploadRecordsToCloudKit(tableName: String, db: Database) throws {
      guard let table = self.tablesByName[tableName]
      else { return }
      func open<T>(_ table: some SynchronizableTable<T>) throws {
        try uploadRecordsToCloudKit(table: table, db: db)
      }
      try open(table)
    }

    private func updateLocalFromSchemaChange(
      previousRecordTypeByTableName: [String: RecordType],
      currentRecordTypeByTableName: [String: RecordType]
    ) async throws {
      let tablesWithChangedSchemas = currentRecordTypeByTableName.filter { tableName, recordType in
        previousRecordTypeByTableName[tableName]?.schema != recordType.schema
      }

      for (tableName, currentRecordType) in tablesWithChangedSchemas {
        guard let table = tablesByName[tableName]
        else { continue }
        func open<T>(_ table: some SynchronizableTable<T>) async throws {
          let previousRecordType = previousRecordTypeByTableName[tableName]
          let changedColumns = currentRecordType.tableInfo.subtracting(
            previousRecordType?.tableInfo ?? []
          )
          .map(\.name)
          let lastKnownServerRecords = try await metadatabase.read { db in
            try SyncMetadata
              .where { $0.recordType.eq(tableName) }
              .select(\._lastKnownServerRecordAllFields)
              .fetchAll(db)
          }
          for case .some(let lastKnownServerRecord) in lastKnownServerRecords {
            let query = try await updateQuery(
              for: table,
              record: lastKnownServerRecord,
              columnNames: T.TableColumns.writableColumns.map(\.name),
              changedColumnNames: changedColumns
            )
            try await userDatabase.write { db in
              try #sql(query).execute(db)
            }
          }
        }
        try await open(table)
      }
    }

    package func tearDownSyncEngine() throws {
      try userDatabase.write { db in
        for name in OutgoingIntent.triggerNames { try db.execute(sql: "DROP TRIGGER IF EXISTS \(name)") }
        try db.execute(sql: "DELETE FROM main.\(OutgoingIntent.table)")
        try db.execute(sql: "DELETE FROM main.\(IncomingJournal.table)")
        try db.execute(sql: "DELETE FROM main.\(IncomingJournal.checkpoints)")
        for table in tables.reversed() {
          try table.base
            .dropTriggers(defaultZone: defaultZone, privateTables: privateTables, db: db)
        }
        for trigger in SyncMetadata.callbackTriggers(for: self).reversed() {
          try trigger.drop().execute(db)
        }
      }
      try metadatabase.erase()
      try migrate(metadatabase: metadatabase)
    }

    /// Deletes synchronized data locally on device and restarts the sync engine.
    ///
    /// This is an explicit destructive action. Account changes retain local data and stop sync.
    /// Call from the resource owner after its delegate callback has returned. Account ownership
    /// is preserved: clearing records never reassigns an owned store to a different account.
    public func deleteLocalData() async throws {
      try await stopAndDrain()
      let lease = try startStopLock.withLock {
        guard !isDraining.value, !isResetting.value, !isRunning else { throw LifetimeError.draining }
        workTracker.activate()
        isResetting.withValue { $0 = true }
        return try workTracker.begin()
      }
      do {
        try await SyncWorkContext.$token.withValue(lease.token) {
          try tearDownSyncEngine()
          try await userDatabase.write { db in
            for table in tables.reversed() {
              func open<T>(_: some SynchronizableTable<T>) throws { try T.unscoped.delete().execute(db) }
              try open(table)
            }
            try setUpSyncEngine(writableDB: db)
          }
        }
        // Finish the maintenance lease before any new generation can start. A concurrent
        // stop invalidates this token and prevents the reset request from restarting later.
        let restarting = try startStopLock.withLock {
          try lease.token.check()
          lease.finish()
          isResetting.withValue { $0 = false }
          return try requestStart()
        }
        try await restarting.value.check()
      } catch {
        startStopLock.withLock { lease.finish(); isResetting.withValue { $0 = false } }
        stop()
        await retirementTask.value?.value
        throw error
      }
    }

    @DatabaseFunction(
      "sqlitedata_icloud_didUpdate",
      as: ((
        String,
        String,
        String,
        String,
        String,
        [String]?.JSONRepresentation
      ) -> Void).self
    )
    func didUpdate(
      recordName: String,
      zoneName: String,
      ownerName: String,
      oldZoneName: String,
      oldOwnerName: String,
      descendantRecordNames: [String]?
    ) {
      var oldChanges: [CKSyncEngine.PendingRecordZoneChange] = []
      var newChanges: [CKSyncEngine.PendingRecordZoneChange] = []

      let oldZoneID = CKRecordZone.ID(zoneName: oldZoneName, ownerName: oldOwnerName)
      let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)

      if oldZoneID != zoneID {
        oldChanges.append(.deleteRecord(CKRecord.ID(recordName: recordName, zoneID: oldZoneID)))
        for descendantRecordName in descendantRecordNames ?? [] {
          oldChanges.append(
            .deleteRecord(CKRecord.ID(recordName: descendantRecordName, zoneID: oldZoneID))
          )
        }
        newChanges.append(.saveRecord(CKRecord.ID(recordName: recordName, zoneID: zoneID)))
        for descendantRecordName in descendantRecordNames ?? [] {
          newChanges.append(
            .saveRecord(CKRecord.ID(recordName: descendantRecordName, zoneID: zoneID))
          )
        }
      } else {
        newChanges.append(
          .saveRecord(CKRecord.ID(recordName: recordName, zoneID: zoneID))
        )
      }

      guard isRunning else { return }
      let oldSyncEngine = self.syncEngines.withValue {
        oldZoneID.ownerName == CKCurrentUserDefaultName ? $0.private : $0.shared
      }
      let syncEngine = self.syncEngines.withValue {
        zoneID.ownerName == CKCurrentUserDefaultName ? $0.private : $0.shared
      }
      oldSyncEngine?.state.add(pendingRecordZoneChanges: oldChanges)
      syncEngine?.state.add(pendingRecordZoneChanges: newChanges)
    }

    @DatabaseFunction(
      "sqlitedata_icloud_didDelete",
      as: ((String, CKRecord?.SystemFieldsRepresentation, CKShare?.SystemFieldsRepresentation)
        -> Void).self
    )
    func didDelete(recordName: String, record: CKRecord?, share: CKShare?) {
      let zoneID = record?.recordID.zoneID ?? defaultZone.zoneID
      var changes: [CKSyncEngine.PendingRecordZoneChange] = [
        .deleteRecord(
          CKRecord.ID(
            recordName: recordName,
            zoneID: zoneID
          )
        )
      ]
      if let share {
        changes.append(.deleteRecord(share.recordID))
      }
      guard isRunning else { return }

      let syncEngine = self.syncEngines.withValue {
        zoneID.ownerName == CKCurrentUserDefaultName ? $0.private : $0.shared
      }
      syncEngine?.state.add(pendingRecordZoneChanges: changes)
    }

    package func acceptShare(metadata: ShareMetadata) async throws {
      try await withSyncWork {
        try await requireAccountOwnership()
        try await acceptShareImpl(metadata: metadata)
      }
    }

    private func acceptShareImpl(metadata: ShareMetadata) async throws {
      guard let rootRecordID = metadata.hierarchicalRootRecordID
      else {
        reportSyncIssue("Attempting to share without root record information.")
        return
      }
      guard accountIsolation == nil || metadata.containerIdentifier == container.containerIdentifier
      else { throw SyncAccountIsolationError.differentEnvironment }
      let container = type(of: container).createContainer(identifier: metadata.containerIdentifier)
      _ = try await container.accept(metadata)
      try await syncEngines.shared?.fetchChanges(
        CKSyncEngine.FetchChangesOptions(
          scope: .zoneIDs([rootRecordID.zoneID]),
          operationGroup: nil
        )
      )
    }

    /// Whether or not the ``SyncEngine`` is currently writing changes to the database.
    ///
    /// See <doc:CloudKitSync#Updating-triggers-to-be-compatible-with-synchronization> for more info.
    @DatabaseFunction("sqlitedata_icloud_syncEngineIsSynchronizingChanges")
    public static var isSynchronizing: Bool {
      if _isCreatingTemporaryTrigger {
        reportIssue(
          """
          Invoked 'SyncEngine.isSynchronizing' at trigger creation, which is unexpected. Use \
          'SyncEngine.$isSynchronizing' to invoke at trigger execution, instead.
          """
        )
      }
      return _isSynchronizingChanges
    }

    @available(*, deprecated, message: "Use 'SyncEngine.$isSynchronizing', instead.")
    public static func isSynchronizingChanges() -> some QueryExpression<Bool> {
      $isSynchronizing
    }

    private var sendingChangesCount: Int {
      get {
        observationRegistrar.access(self, keyPath: \.isSendingChanges)
        return activityCounts.withValue(\.sendingChangesCount)
      }
      set {
        observationRegistrar.withMutation(of: self, keyPath: \.isSendingChanges) {
          activityCounts.withValue { $0.sendingChangesCount = newValue }
        }
      }
    }
    private var fetchingChangesCount: Int {
      get {
        observationRegistrar.access(self, keyPath: \.isFetchingChanges)
        return activityCounts.withValue(\.fetchingChangesCount)
      }
      set {
        observationRegistrar.withMutation(of: self, keyPath: \.isFetchingChanges) {
          activityCounts.withValue { $0.fetchingChangesCount = newValue }
        }
      }
    }
  }

  extension PrimaryKeyedTable {
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    fileprivate static func createTriggers(
      foreignKeysByTableName: [String: [ForeignKey]],
      tablesByName: [String: any SynchronizableTable],
      defaultZone: CKRecordZone,
      privateTables: [any SynchronizableTable],
      db: Database
    ) throws {
      let parentForeignKey =
        foreignKeysByTableName[tableName]?.count == 1
        ? foreignKeysByTableName[tableName]?.first
        : nil

      for trigger in metadataTriggers(
        parentForeignKey: parentForeignKey,
        defaultZone: defaultZone,
        privateTables: privateTables
      ) {
        try trigger.execute(db)
      }
    }

    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    fileprivate static func dropTriggers(
      defaultZone: CKRecordZone,
      privateTables: [any SynchronizableTable],
      db: Database
    ) throws {
      for trigger in metadataTriggers(
        parentForeignKey: nil,
        defaultZone: defaultZone,
        privateTables: privateTables
      )
      .reversed() {
        try trigger.drop().execute(db)
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine: CKSyncEngineDelegate {
    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
      guard let event = Event(event)
      else {
        reportSyncIssue("Unrecognized event received: \(event)")
        return
      }
      await handleEvent(event, syncEngine: syncEngine)
    }

    package func handleEvent(_ event: Event, syncEngine: any SyncEngineProtocol) async {
      guard acceptsCallback(from: syncEngine) else { return }
      do {
        try await withSyncWork {
          if case .accountChange = event { }
          else { try await requireAccountOwnership() }
          try SyncWorkContext.token?.check()
          await diagnoseEvent(event, engine: syncEngine) {
            await handleEventImpl(event, syncEngine: syncEngine)
          }
        }
      } catch is CancellationError { }
      catch { diagnosticFailure(error) }
    }

    private func handleEventImpl(_ event: Event, syncEngine: any SyncEngineProtocol) async {
      #if DEBUG
        logger.log(event, syncEngine: syncEngine)
      #endif

      switch event {
      case .accountChange(let changeType):
        fetchCompletion.withValue { $0.accountGeneration += 1 }
        await handleAccountChange(changeType: changeType, syncEngine: syncEngine)
      case .stateUpdate(let stateSerialization):
        await handleStateUpdate(stateSerialization: stateSerialization, syncEngine: syncEngine)
      case .fetchedDatabaseChanges(let modifications, let deletions):
        await handleFetchedDatabaseChanges(
          modifications: modifications,
          deletions: deletions,
          syncEngine: syncEngine
        )
      case .sentDatabaseChanges:
        break
      case .fetchedRecordZoneChanges(let modifications, let deletions):
        await handleFetchedRecordZoneChanges(
          modifications: modifications,
          deletions: deletions,
          syncEngine: syncEngine
        )
      case .sentRecordZoneChanges(
        let savedRecords,
        let failedRecordSaves,
        let deletedRecordIDs,
        let failedRecordDeletes
      ):
        await handleSentRecordZoneChanges(
          savedRecords: savedRecords,
          failedRecordSaves: failedRecordSaves,
          deletedRecordIDs: deletedRecordIDs,
          failedRecordDeletes: failedRecordDeletes,
          syncEngine: syncEngine
        )

      case .willFetchRecordZoneChanges:
        await MainActor.run {
          startStopLock.withLock {
            guard (try? SyncWorkContext.token?.check()) != nil else { return }
            fetchingChangesCount += 1
          }
        }
      case .didFetchRecordZoneChanges(_, let error):
        if let error {
          fetchCompletion.withValue {
            $0.zoneFailureGeneration += 1
            $0.zoneFailure = error
          }
        }
        await MainActor.run {
          startStopLock.withLock {
            guard (try? SyncWorkContext.token?.check()) != nil else { return }
            fetchingChangesCount -= 1
          }
        }

      case .willFetchChanges:
        await MainActor.run {
          startStopLock.withLock {
            guard (try? SyncWorkContext.token?.check()) != nil else { return }
            fetchingChangesCount += 1
          }
        }
      case .didFetchChanges:
        await recoverLegacyIncomingRecords(engine: syncEngine)
        await replayIncomingChanges()
        fetchCompletion.withValue { $0.completed[ObjectIdentifier(syncEngine), default: 0] += 1 }
        await MainActor.run {
          startStopLock.withLock {
            guard (try? SyncWorkContext.token?.check()) != nil else { return }
            fetchingChangesCount -= 1
          }
        }

      case .willSendChanges:
        await MainActor.run {
          startStopLock.withLock {
            guard (try? SyncWorkContext.token?.check()) != nil else { return }
            sendingChangesCount += 1
          }
        }
      case .didSendChanges:
        outgoingAttempts.finish(engine: syncEngine)
        await MainActor.run {
          startStopLock.withLock {
            guard (try? SyncWorkContext.token?.check()) != nil else { return }
            sendingChangesCount -= 1
          }
        }

      @unknown default:
        break
      }
    }

    public func nextRecordZoneChangeBatch(
      _ context: CKSyncEngine.SendChangesContext,
      syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
      await nextRecordZoneChangeBatch(
        reason: context.reason,
        options: context.options,
        syncEngine: syncEngine
      )
    }

    package func nextRecordZoneChangeBatch(
      reason: CKSyncEngine.SyncReason = .scheduled,
      options: CKSyncEngine.SendChangesOptions = CKSyncEngine.SendChangesOptions(scope: .all),
      syncEngine: any SyncEngineProtocol
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
      guard acceptsCallback(from: syncEngine) else { return nil }
      do {
        return try await withSyncWork {
          try await requireAccountOwnership()
          let batch = await preparedBatch(reason: reason, options: options, syncEngine: syncEngine)
          try await requireAccountOwnership()
          try SyncWorkContext.token?.check()
          return batch
        }
      } catch is CancellationError { return nil }
      catch { diagnosticFailure(error); return nil }
    }

    private func preparedBatch(
      reason: CKSyncEngine.SyncReason, options: CKSyncEngine.SendChangesOptions,
      syncEngine: any SyncEngineProtocol
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
      let key = SyncDiagnosticEmitter.TransferKey(engine: ObjectIdentifier(syncEngine), sending: true)
      let parent = diagnosticEmitter?.transfers.value[key]
      let context = diagnosticEmitter.map { _ in
        makeDiagnosticOperation(
          scope: syncEngine.database.databaseScope == .shared ? .shared : .private,
          stage: .batchPrepared, parent: parent
        )
      }
      return await SyncDiagnosticContext.$operation.withValue(context) {
        await nextDiagnosticBatch(reason: reason, options: options, syncEngine: syncEngine)
      }
    }

    private func nextDiagnosticBatch(
      reason: CKSyncEngine.SyncReason, options: CKSyncEngine.SendChangesOptions,
      syncEngine: any SyncEngineProtocol
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
      var changes = await pendingRecordZoneChanges(options: options, syncEngine: syncEngine)
      guard !changes.isEmpty
      else { return nil }

      changes.sort { lhs, rhs in
        switch (lhs, rhs) {
        case (.saveRecord(let lhs), .saveRecord(let rhs)):
          guard
            let lhsRecordType = lhs.tableName,
            let lhsIndex = tablesByOrder[lhsRecordType],
            let rhsRecordType = rhs.tableName,
            let rhsIndex = tablesByOrder[rhsRecordType]
          else { return true }
          return lhsIndex < rhsIndex
        case (.deleteRecord(let lhs), .deleteRecord(let rhs)):
          guard
            let lhsRecordType = lhs.tableName,
            let lhsIndex = tablesByOrder[lhsRecordType],
            let rhsRecordType = rhs.tableName,
            let rhsIndex = tablesByOrder[rhsRecordType]
          else { return true }
          return lhsIndex > rhsIndex
        case (.saveRecord, .deleteRecord):
          return false
        case (.deleteRecord, .saveRecord):
          return true
        default:
          return true
        }
      }

      #if DEBUG
        let state = LockIsolated(NextRecordZoneChangeBatchLoggingState())
        defer {
          let state = state.withValue(\.self)
          if let tabularDescription = state.tabularDescription {
            logger.debug(
              """
              SQLiteData (\(syncEngine.database.databaseScope.label).db) \
              nextRecordZoneChangeBatch: \(reason)
                \(tabularDescription)
              """
            )
          }
        }
      #endif

      let diagnosticOperation = SyncDiagnosticContext.operation
      let workToken = SyncWorkContext.token
      let batch = await syncEngine.recordZoneChangeBatch(pendingChanges: changes) { recordID in
        await SyncWorkContext.$token.withValue(workToken) {
        await SyncDiagnosticContext.$operation.withValue(diagnosticOperation) {
          guard
            let metadata = await withDiagnosticErrorReporting(
              .sqliteDataCloudKitFailure,
              catching: {
                try await metadatabase.read { db in
                  try SyncMetadata
                    .find(recordID)
                    .fetchOne(db)
                }
              }
            )
              ?? nil
          else {
            SyncDiagnosticContext.operation?.increment("skipped")
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            return nil
          }

          var missingTable: CKRecord.ID?
          var missingRecord: CKRecord.ID?
          var sentRecord: CKRecord.ID?
          #if DEBUG
            defer {
              state.withValue { [missingTable, missingRecord, sentRecord] in
                if let missingTable {
                  $0.events.append("⚠️ Missing table")
                  $0.recordTypes.append(metadata.recordType)
                  $0.recordNames.append(missingTable.recordName)
                }
                if let missingRecord {
                  $0.events.append("⚠️ Missing record")
                  $0.recordTypes.append(metadata.recordType)
                  $0.recordNames.append(missingRecord.recordName)
                }
                if let sentRecord {
                  $0.events.append("➡️ Sending")
                  $0.recordTypes.append(metadata.recordType)
                  $0.recordNames.append(sentRecord.recordName)
                }
              }
            }
          #endif

          guard let table = tablesByName[metadata.recordType]
          else {
            syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
            missingTable = recordID
            SyncDiagnosticContext.operation?.increment("skipped")
            return nil
          }
          func open<T>(_: some SynchronizableTable<T>) async -> CKRecord? {
            let prepared = await withDiagnosticErrorReporting(.sqliteDataCloudKitFailure) {
              try await userDatabase.write { db -> (CKRecord, String)? in
                guard let revision = try OutgoingIntent.revision(db, for: recordID, isDelete: false),
                  let current = try SyncMetadata.find(recordID).fetchOne(db),
                  !current._isDeleted,
                  let row = try T.unscoped.where({
                    #sql("\($0.primaryKey) = \(bind: current.recordPrimaryKey)")
                  }).fetchOne(db)
                else {
                  SyncDiagnosticContext.operation?.increment("skipped")
                  return nil
                }
                let record = current._lastKnownServerRecordAllFields
                  ?? CKRecord(recordType: current.recordType, recordID: recordID)
                if let parent = current.parentRecordName,
                  !privateTables.contains(where: { $0.base.tableName == current.recordType }) {
                  record.parent = CKRecord.Reference(recordID: .init(recordName: parent, zoneID: recordID.zoneID), action: .none)
                } else { record.parent = nil }
                let encodingFailed = LockIsolated(false)
                SyncRecordEncodingContext.$failed.withValue(encodingFailed) {
                  record.update(with: T(queryOutput: row), userModificationTime: current.userModificationTime)
                }
                guard !encodingFailed.value else {
                  SyncDiagnosticContext.operation?.increment("skipped")
                  return nil
                }
                try refreshLastKnownServerRecord(record, db: db)
                return (record, revision)
              }
            } ?? nil
            guard let (record, revision) = prepared else { return nil }
            outgoingAttempts.prepared(OutgoingIntent(recordID: recordID, revision: revision, isDelete: false),
                                      engine: syncEngine)
            return record
          }
          let record = await open(table)
          if record == nil { missingRecord = recordID }
          else { sentRecord = recordID }
          return record
        }
        }
      }
      let diagnosticCounts = SyncDiagnosticContext.operation?.counts.value ?? [:]
      let incomplete = diagnosticCounts["errors", default: 0] > 0 || diagnosticCounts["skipped", default: 0] > 0
      emitDiagnostic(.batchPrepared, level: incomplete ? .warning : .debug,
                     outcome: incomplete ? .partial : .prepared,
                     counts: diagnosticCounts.merging(["requestedChanges": changes.count]) { _, new in new },
                     recordTypes: diagnosticRecordTypes(changes.compactMap { $0.id?.tableName }))
      return batch
    }

    private func pendingRecordZoneChanges(
      options: CKSyncEngine.SendChangesOptions,
      syncEngine: any SyncEngineProtocol
    ) async -> [CKSyncEngine.PendingRecordZoneChange] {
      guard var changes = await withDiagnosticErrorReporting(.sqliteDataCloudKitFailure, catching: {
        try await durablePendingChanges(options: options, syncEngine: syncEngine)
      }) else { return [] }
      guard !changes.isEmpty
      else { return [] }

      let deletedRecordIDs: [CKRecord.ID] = changes.compactMap {
        switch $0 {
        case .saveRecord(_):
          return nil
        case .deleteRecord(let recordID):
          return recordID
        @unknown default:
          return nil
        }
      }

      if syncEngine.database.databaseScope == .shared {
        let (sharesToDelete, recordsWithRoot):
          ([CKShare?], [(lastKnownServerRecord: CKRecord?, rootLastKnownServerRecord: CKRecord?)]) =
            await withDiagnosticErrorReporting(.sqliteDataCloudKitFailure) {
              guard !deletedRecordIDs.isEmpty
              else { return ([], []) }

              return try await metadatabase.read { db in
                let sharesToDelete =
                  try SyncMetadata
                  .findAll(deletedRecordIDs)
                  .where(\.isShared)
                  .select(\.share)
                  .fetchAll(db)

                let recordsWithRoot =
                  try With {
                    SyncMetadata
                      .findAll(deletedRecordIDs)
                      .where { $0.parentRecordName.is(nil) }
                      .select {
                        RecordWithRoot.Columns(
                          parentRecordName: $0.parentRecordName,
                          recordName: $0.recordName,
                          lastKnownServerRecord: $0.lastKnownServerRecord,
                          rootRecordName: $0.recordName,
                          rootLastKnownServerRecord: $0.lastKnownServerRecord
                        )
                      }
                      .union(
                        all: true,
                        SyncMetadata
                          .join(RecordWithRoot.all) { $1.recordName.is($0.parentRecordName) }
                          .select { metadata, tree in
                            RecordWithRoot.Columns(
                              parentRecordName: metadata.parentRecordName,
                              recordName: metadata.recordName,
                              lastKnownServerRecord: metadata.lastKnownServerRecord,
                              rootRecordName: tree.rootRecordName,
                              rootLastKnownServerRecord: tree.rootLastKnownServerRecord
                            )
                          }
                      )
                  } query: {
                    RecordWithRoot
                      .select { ($0.lastKnownServerRecord, $0.rootLastKnownServerRecord) }
                  }
                  .fetchAll(db)

                return (sharesToDelete, recordsWithRoot)
              }
            }
            ?? ([], [])

        let shareRecordIDsToDelete = sharesToDelete.compactMap(\.?.recordID)

        for recordWithRoot in recordsWithRoot {
          guard
            let lastKnownServerRecord = recordWithRoot.lastKnownServerRecord,
            let rootLastKnownServerRecord = recordWithRoot.rootLastKnownServerRecord
          else { continue }
          guard let rootShareRecordID = rootLastKnownServerRecord.share?.recordID
          else { continue }
          guard shareRecordIDsToDelete.contains(rootShareRecordID)
          else { continue }
          await withDiagnosticErrorReporting(.sqliteDataCloudKitFailure) {
            try await userDatabase.read { db in
              if let revision = try OutgoingIntent.revision(db, for: lastKnownServerRecord.recordID, isDelete: true) {
                outgoingAttempts.cover(OutgoingIntent(recordID: lastKnownServerRecord.recordID,
                  revision: revision, isDelete: true), by: rootShareRecordID, engine: syncEngine)
              }
            }
          }
          changes.removeAll(where: { $0 == .deleteRecord(lastKnownServerRecord.recordID) })
          syncEngine.state.remove(
            pendingRecordZoneChanges: [.deleteRecord(lastKnownServerRecord.recordID)]
          )
        }
      }

      let deletedChanges = changes
      await withDiagnosticErrorReporting(.sqliteDataCloudKitFailure) {
        try await userDatabase.read { db in
          for case .deleteRecord(let id) in deletedChanges {
            if let revision = try OutgoingIntent.revision(db, for: id, isDelete: true) {
              outgoingAttempts.prepared(OutgoingIntent(recordID: id, revision: revision, isDelete: true),
                                        engine: syncEngine)
            }
          }
        }
      }

      return changes
    }

    package func handleAccountChange(
      changeType: CKSyncEngine.Event.AccountChange.ChangeType,
      syncEngine: any SyncEngineProtocol
    ) async {
      guard acceptsCallback(from: syncEngine) else { return }
      switch changeType {
      case .signIn:
        do {
          try await requireAccountOwnership()
          guard syncEngine === syncEngines.private else { return }
          syncEngine.state.add(pendingDatabaseChanges: [.saveZone(defaultZone)])
          try await enqueueUnknownRecordsForCloudKit()
        } catch { diagnosticFailure(error) }
      case .signOut:
        setAccountFailure(.accountUnavailable(.noAccount))
        stop()
      case .switchAccounts:
        setAccountFailure(.differentAccount)
        stop()
      @unknown default:
        stop()
      }
      // Notification happens after fencing. The delegate must return before the owner awaits
      // retirement; it must not erase or replace the store from inside this callback.
      await delegate?.syncEngine(self, accountChanged: changeType)
    }

    package func handleStateUpdate(
      stateSerialization: CKSyncEngine.State.Serialization, syncEngine: any SyncEngineProtocol
    ) async {
      await commitIncomingCheckpoint(stateSerialization, engine: syncEngine)
    }

    package func handleFetchedDatabaseChanges(
      modifications: [CKRecordZone.ID],
      deletions: [(zoneID: CKRecordZone.ID, reason: CKDatabase.DatabaseChange.Deletion.Reason)],
      syncEngine: any SyncEngineProtocol
    ) async {
      await captureIncomingZones(deletions: deletions, engine: syncEngine)
      if let mock = syncEngine as? MockSyncEngine { await commitMockIncomingCheckpoint(mock) }
    }

    package func handleFetchedRecordZoneChanges(
      modifications: [CKRecord] = [],
      deletions: [(recordID: CKRecord.ID, recordType: CKRecord.RecordType)] = [],
      syncEngine: any SyncEngineProtocol
    ) async {
      await captureIncoming(modifications: modifications, deletions: deletions, engine: syncEngine)
      if let mock = syncEngine as? MockSyncEngine { await commitMockIncomingCheckpoint(mock) }
      await recoverLegacyIncomingRecords(engine: syncEngine)
    }

    private func topologicallyAscending(
      lhsTableName: String?,
      rhsTableName: String?,
      rootFirst: Bool
    ) -> Bool {
      switch (lhsTableName, rhsTableName) {
      case (nil, nil), (nil, _):
        return false
      case (_, nil):
        return true
      case (.some(let lhs), .some(let rhs)):
        let lhsIndex = tablesByOrder[lhs] ?? (rootFirst ? .max : .min)
        let rhsIndex = tablesByOrder[rhs] ?? (rootFirst ? .max : .min)
        guard lhsIndex != rhsIndex
        else {
          return lhs < rhs
        }
        return rootFirst ? lhsIndex < rhsIndex : lhsIndex > rhsIndex
      }
    }

    package func handleSentRecordZoneChanges(
      savedRecords: [CKRecord] = [],
      failedRecordSaves: [(record: CKRecord, error: CKError)] = [],
      deletedRecordIDs: [CKRecord.ID] = [],
      failedRecordDeletes: [CKRecord.ID: CKError] = [:],
      syncEngine: any SyncEngineProtocol
    ) async {
      let failureGuards = await acknowledgeOutgoing(savedRecords: savedRecords, deletedRecordIDs: deletedRecordIDs,
        failedRecordSaves: failedRecordSaves, failedRecordDeletes: failedRecordDeletes, syncEngine: syncEngine)

      var newPendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] = []
      var newPendingDatabaseChanges: [CKSyncEngine.PendingDatabaseChange] = []
      defer {
        syncEngine.state.add(pendingDatabaseChanges: newPendingDatabaseChanges)
        syncEngine.state.add(pendingRecordZoneChanges: newPendingRecordZoneChanges)
        if !newPendingDatabaseChanges.isEmpty || !newPendingRecordZoneChanges.isEmpty {
          emitDiagnostic(.retryEnqueued, level: .warning,
                         counts: ["zones": newPendingDatabaseChanges.count,
                                  "records": newPendingRecordZoneChanges.count])
        }
      }
      for (failedRecord, error) in failedRecordSaves {
        let failureGuard = failureGuards.saves[failedRecord.recordID]
        func clearServerRecord() async {
          await withDiagnosticErrorReporting(.sqliteDataCloudKitFailure) {
            try await userDatabase.write { db in
              guard try failureGuard?.allowsRecovery(db) != false else { return }
              try SyncMetadata
                .find(failedRecord.recordID)
                .update { $0.setLastKnownServerRecord(nil) }
                .execute(db)
            }
          }
        }

        switch error.code {
        case .serverRecordChanged:
          guard let serverRecord = error.serverRecord else { continue }
          await upsertFromServerRecord(serverRecord, failureGuard: failureGuard)
          newPendingRecordZoneChanges.append(.saveRecord(failedRecord.recordID))

        case .zoneNotFound:
          let zone = CKRecordZone(zoneID: failedRecord.recordID.zoneID)
          newPendingDatabaseChanges.append(.saveZone(zone))
          newPendingRecordZoneChanges.append(.saveRecord(failedRecord.recordID))
          await clearServerRecord()

        case .unknownItem:
          newPendingRecordZoneChanges.append(.saveRecord(failedRecord.recordID))
          await clearServerRecord()

        case .serverRejectedRequest:
          // A replay of a create may already exist after its first acknowledgement was lost.
          if let serverRecord = error.serverRecord {
            await upsertFromServerRecord(serverRecord, failureGuard: failureGuard)
            newPendingRecordZoneChanges.append(.saveRecord(failedRecord.recordID))
          } else {
            await clearServerRecord()
          }

        case .referenceViolation:
          guard
            let recordPrimaryKey = failedRecord.recordID.recordPrimaryKey,
            let table = tablesByName[failedRecord.recordType],
            foreignKeysByTableName[table.base.tableName]?.count == 1,
            let foreignKey = foreignKeysByTableName[table.base.tableName]?.first
          else {
            continue
          }
          func open<T>(_: some SynchronizableTable<T>) async throws {
            try await userDatabase.write { db in
              guard try failureGuard?.allowsRecovery(db) != false else { return }
              try $_isSynchronizingChanges.withValue(false) {
                switch foreignKey.onDelete {
                case .cascade:
                  try T
                    .unscoped
                    .where { #sql("\($0.primaryKey) = \(bind: recordPrimaryKey)") }
                    .delete()
                    .execute(db)
                case .restrict:
                  preconditionFailure(
                    "'RESTRICT' foreign key actions not supported for parent relationships."
                  )
                case .setDefault:
                  guard
                    let recordType = try RecordType.find(T.tableName).fetchOne(db),
                    let columnInfo = recordType.tableInfo.first(where: {
                      $0.name == foreignKey.from
                    })
                  else { return }
                  let defaultValue = columnInfo.defaultValue ?? "NULL"
                  try #sql(
                    """
                    UPDATE \(T.self)
                    SET \(quote: foreignKey.from, delimiter: .identifier) = (\(raw: defaultValue))
                    WHERE (\(T.primaryKey)) = (\(bind: recordPrimaryKey))
                    """
                  )
                  .execute(db)
                  break
                case .setNull:
                  try #sql(
                    """
                    UPDATE \(T.self)
                    SET \(quote: foreignKey.from, delimiter: .identifier) = NULL
                    WHERE (\(T.primaryKey)) = (\(bind: recordPrimaryKey))
                    """
                  )
                  .execute(db)
                case .noAction:
                  preconditionFailure(
                    "'NO ACTION' foreign key actions not supported for parent relationships."
                  )
                }
              }
            }
          }
          await withDiagnosticErrorReporting(.sqliteDataCloudKitFailure) {
            try await open(table)
          }

        case .permissionFailure:
          guard
            let recordPrimaryKey = failedRecord.recordID.recordPrimaryKey,
            let table = tablesByName[failedRecord.recordType]
          else { continue }
          func open<T>(_: some SynchronizableTable<T>) async throws {
            do {
              let serverRecord = try await container.sharedCloudDatabase.record(
                for: failedRecord.recordID
              )
              await upsertFromServerRecord(serverRecord, force: true, failureGuard: failureGuard)
            } catch let error as CKError where error.code == .unknownItem {
              try await userDatabase.write { db in
                guard try failureGuard?.allowsRecovery(db) != false else { return }
                try T
                  .unscoped
                  .where { #sql("\($0.primaryKey) = \(bind: recordPrimaryKey)") }
                  .delete()
                  .execute(db)
              }
            }
          }
          await withDiagnosticErrorReporting(.sqliteDataCloudKitFailure) {
            try await open(table)
          }

        case .batchRequestFailed:
          newPendingRecordZoneChanges.append(.saveRecord(failedRecord.recordID))
          break

        case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
          .notAuthenticated, .operationCancelled,
          .internalError, .partialFailure, .badContainer, .requestRateLimited, .missingEntitlement,
          .invalidArguments, .resultsTruncated, .assetFileNotFound,
          .assetFileModified, .incompatibleVersion, .constraintViolation, .changeTokenExpired,
          .badDatabase, .quotaExceeded, .limitExceeded, .userDeletedZone, .tooManyParticipants,
          .alreadyShared, .managedAccountRestricted, .participantMayNeedVerification,
          .serverResponseLost, .assetNotAvailable, .accountTemporarilyUnavailable:
          continue
        #if canImport(FoundationModels)
          case .participantAlreadyInvited:
            continue
        #endif
        @unknown default:
          continue
        }
      }

      let enqueuedUnsyncedRecordID =
        await withDiagnosticErrorReporting(.sqliteDataCloudKitFailure) {
          try await userDatabase.write { db in
            var enqueuedUnsyncedRecordID = false
            for (failedRecordID, error) in failedRecordDeletes {
              switch error.code {
              case .referenceViolation:
                guard try failureGuards.deletes[failedRecordID]?.allowsRecovery(db) != false else { continue }
                enqueuedUnsyncedRecordID = true
                try UnsyncedRecordID.insert {
                  UnsyncedRecordID(recordID: failedRecordID)
                } onConflictDoUpdate: { _ in
                }
                .execute(db)
                syncEngine.state.remove(pendingRecordZoneChanges: [.deleteRecord(failedRecordID)])
                break
              case .batchRequestFailed:
                syncEngine.state.add(pendingRecordZoneChanges: [.deleteRecord(failedRecordID)])
                break
              case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                .notAuthenticated, .operationCancelled, .internalError, .partialFailure,
                .badContainer, .requestRateLimited, .missingEntitlement, .invalidArguments,
                .resultsTruncated, .assetFileNotFound, .assetFileModified, .incompatibleVersion,
                .constraintViolation, .changeTokenExpired, .badDatabase, .quotaExceeded,
                .limitExceeded, .userDeletedZone, .tooManyParticipants, .alreadyShared,
                .managedAccountRestricted, .participantMayNeedVerification, .serverResponseLost,
                .assetNotAvailable, .accountTemporarilyUnavailable, .permissionFailure,
                .unknownItem, .serverRecordChanged, .serverRejectedRequest, .zoneNotFound:
                break
              #if canImport(FoundationModels)
                case .participantAlreadyInvited:
                  break
              #endif
              @unknown default:
                break
              }
            }
            return enqueuedUnsyncedRecordID
          }
        }
        ?? false
      if enqueuedUnsyncedRecordID {
        await handleFetchedRecordZoneChanges(syncEngine: syncEngine)
      }
      await withDiagnosticErrorReporting(.sqliteDataCloudKitFailure) {
        try await enqueueOutgoingIntents()
      }
    }

    private func cacheShare(_ share: CKShare) async throws {
      let metadata = try await container.shareMetadata(for: share, shouldFetchRootRecord: false)
      guard let rootRecordID = metadata.hierarchicalRootRecordID
      else { return }
      try await userDatabase.write { db in
        try SyncMetadata
          .find(rootRecordID)
          .update { $0.share = #bind(share) }
          .execute(db)
      }
    }

    func deleteShare(shareRecordID: CKRecord.ID) async throws {
      try await withSyncWork {
        try await requireAccountOwnership()
        try await deleteOwnedShare(shareRecordID: shareRecordID)
      }
    }

    private func deleteOwnedShare(shareRecordID: CKRecord.ID) async throws {
      let shareAndRecordNameAndZone = try await metadatabase.read { db in
        try SyncMetadata
          .where(\.isShared)
          .select { ($0.share, $0.recordName, $0.zoneName, $0.ownerName) }
          .fetchAll(db)
          .first(where: { share, _, _, _ in share?.recordID == shareRecordID }) ?? nil
      }
      guard let (_, recordName, zoneName, ownerName) = shareAndRecordNameAndZone
      else { return }
      let rootRecordID = CKRecord.ID(
        recordName: recordName,
        zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
      )
      let rootRecord = try await container.privateCloudDatabase.record(for: rootRecordID)
      try await requireAccountOwnership()
      try await userDatabase.write { db in
        try SyncMetadata
          .find(
            CKRecord.ID(
              recordName: recordName,
              zoneID: CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName)
            )
          )
          .update {
            $0.setLastKnownServerRecord(rootRecord)
            $0.share = #bind(nil)
          }
          .execute(db)
      }
    }

    private func upsertFromServerRecord(
      _ serverRecord: CKRecord,
      force: Bool = false,
      failureGuard: OutgoingFailureGuard? = nil
    ) async {
      await withFetchErrorReporting {
        try await requireAccountOwnership()
        try await userDatabase.write { db in
          guard try failureGuard?.allowsRecovery(db) != false else { return }
          upsertFromServerRecord(serverRecord, force: force, db: db)
        }
      }
    }

    func upsertFromServerRecord(
      _ serverRecord: CKRecord,
      force: Bool = false,
      db: Database
    ) {
      withFetchErrorReporting {
        guard
          let recordPrimaryKey = serverRecord.recordID.recordPrimaryKey,
          serverRecord.encryptedValues[CKRecord.userModificationTimeKey] != nil
        else {
          if tablesByName[serverRecord.recordType] != nil {
            diagnosticFailure(FetchCompletionError.invalidRecord(serverRecord.recordID))
            // Preserve ordinary fetch's ignored-record behavior, but not checked success.
            let error = FetchCompletionError.invalidRecord(serverRecord.recordID)
            if let failure = IncomingApplyContext.failure { failure.withValue { $0 = $0 ?? error } }
            else {
              fetchCompletion.withValue {
                $0.localFailure = $0.localFailure ?? error
                $0.untrackedLocalFailure = $0.untrackedLocalFailure ?? error
              }
            }
          } else {
            SyncDiagnosticContext.operation?.increment("ignored")
          }
          return
        }

        try SyncMetadata.insert {
          SyncMetadata(
            recordPrimaryKey: recordPrimaryKey,
            recordType: serverRecord.recordType,
            zoneName: serverRecord.recordID.zoneID.zoneName,
            ownerName: serverRecord.recordID.zoneID.ownerName,
            parentRecordPrimaryKey: serverRecord.parent?.recordID.recordPrimaryKey,
            parentRecordType: serverRecord.parent?.recordID.tableName,
            lastKnownServerRecord: serverRecord,
            _lastKnownServerRecordAllFields: serverRecord,
            share: nil,
            userModificationTime: serverRecord.userModificationTime
          )
        } onConflict: {
          ($0.recordPrimaryKey, $0.recordType)
        } doUpdate: {
          if tablesByName[serverRecord.recordType] == nil {
            $0.setLastKnownServerRecord(serverRecord)
          } else {
            $0.zoneName = serverRecord.recordID.zoneID.zoneName
            $0.ownerName = serverRecord.recordID.zoneID.ownerName
          }
        }
        .execute(db)

        guard
          let metadata = try SyncMetadata.find(serverRecord.recordID).fetchOne(db),
          let table = tablesByName[serverRecord.recordType]
        else {
          SyncDiagnosticContext.operation?.increment("ignored")
          return
        }

        serverRecord.userModificationTime = metadata.userModificationTime

        func open<T>(_ table: some SynchronizableTable<T>) throws {
          var columnNames: [String] = T.TableColumns.writableColumns.map(\.name)
          if !force,
            let allFields = metadata._lastKnownServerRecordAllFields,
            let row = try T.unscoped.find(#sql("\(bind: metadata.recordPrimaryKey)")).fetchOne(db)
          {
            serverRecord.update(
              with: allFields,
              row: T(queryOutput: row),
              columnNames: &columnNames,
              parentForeignKey: foreignKeysByTableName[T.tableName]?.count == 1
                ? foreignKeysByTableName[T.tableName]?.first
                : nil
            )
          }

          do {
            try $_currentZoneID.withValue(serverRecord.recordID.zoneID) {
              try #sql(try upsert(table, record: serverRecord, columnNames: columnNames)).execute(db)
            }
            try UnsyncedRecordID.find(serverRecord.recordID).delete().execute(db)
            try SyncMetadata
              .find(serverRecord.recordID)
              .update { $0.setLastKnownServerRecord(serverRecord) }
              .execute(db)
          } catch {
            guard
              let error = error as? DatabaseError,
              error.resultCode == .SQLITE_CONSTRAINT,
              error.extendedResultCode == .SQLITE_CONSTRAINT_FOREIGNKEY
            else {
              throw error
            }
            SyncDiagnosticContext.operation?.increment("deferred")
            try UnsyncedRecordID.insert {
              UnsyncedRecordID(recordID: serverRecord.recordID)
            } onConflictDoUpdate: { _ in
            }
            .execute(db)
          }
        }
        try open(table)
      }
    }

    private func updateQuery<T>(
      for _: some SynchronizableTable<T>,
      record: CKRecord,
      columnNames: some Collection<String>,
      changedColumnNames: some Collection<String>
    ) async throws -> QueryFragment {
      let nonPrimaryKeyChangedColumns =
        changedColumnNames
        .filter {
          $0 != T.primaryKey.name && record.hasSet(key: $0)
        }
      guard
        !nonPrimaryKeyChangedColumns.isEmpty
      else {
        return ""
      }
      var record = record
      let recordHasAsset = nonPrimaryKeyChangedColumns.contains { columnName in
        record[columnName] is CKAsset
      }
      if recordHasAsset {
        record = try await container.database(for: record.recordID).record(for: record.recordID)
        try await requireAccountOwnership()
      }

      var query: QueryFragment = "INSERT INTO \(T.self) ("
      query.append(columnNames.map { "\(quote: $0)" }.joined(separator: ", "))
      query.append(") VALUES (")
      query.append(
        columnNames
          .map { columnName in
            if let asset = record[columnName] as? CKAsset {
              let data = try? asset.fileURL.map { try dataManager.wrappedValue.load($0) }
              if data == nil {
                reportSyncIssue("Asset data not found on disk")
              }
              return data?.queryFragment ?? "NULL"
            } else {
              return record.encryptedValues[columnName]?.queryFragment ?? "NULL"
            }
          }
          .joined(separator: ", ")
      )
      query.append(") ON CONFLICT(\(quote: T.primaryKey.name)) DO UPDATE SET ")
      query.append(" ")
      query.append(
        nonPrimaryKeyChangedColumns
          .map { columnName in
            if let asset = record[columnName] as? CKAsset {
              let data = try? asset.fileURL.map { try dataManager.wrappedValue.load($0) }
              if data == nil {
                reportSyncIssue("Asset data not found on disk")
              }
              return
                "\(quote: columnName) = \(data?.queryFragment ?? #""excluded".\#(quote: columnName)"#)"
            } else {
              return """
                \(quote: columnName) = \
                \(record.encryptedValues[columnName]?.queryFragment ?? #""excluded".\#(quote: columnName)"#)
                """
            }
          }
          .joined(separator: ",")
      )
      return query
    }
  }

  @available(macOS 14, iOS 17, tvOS 17, watchOS 10, *)
  extension CKSyncEngine.PendingRecordZoneChange {
    var id: CKRecord.ID? {
      switch self {
      case .saveRecord(let id):
        return id
      case .deleteRecord(let id):
        return id
      @unknown default:
        return nil
      }
    }
  }

  extension CKRecord.ID {
    var tableName: String? {
      guard
        let i = recordName.utf8.lastIndex(of: UTF8.CodeUnit(ascii: ":")),
        let j = recordName.utf8.index(i, offsetBy: 1, limitedBy: recordName.utf8.endIndex)
      else { return nil }
      let recordTypeBytes = recordName.utf8[j...]
      guard !recordTypeBytes.isEmpty else { return nil }
      return String(Substring(recordTypeBytes))
    }

    var recordPrimaryKey: String? {
      guard
        let i = recordName.utf8.lastIndex(of: UTF8.CodeUnit(ascii: ":"))
      else { return nil }
      let recordPrimaryKeyBytes = recordName.utf8[..<i]
      guard
        !recordPrimaryKeyBytes.isEmpty
      else { return nil }
      return String(Substring(recordPrimaryKeyBytes))
    }
  }

  extension String {
    package static let sqliteDataCloudKitSchemaName = "sqlitedata_icloud"
    package static let sqliteDataCloudKitFailure = "SQLiteData CloudKit Failure"
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension URL {
    package static func metadatabase(
      databasePath: String,
      containerIdentifier: String?
    ) throws -> URL {
      let databasePath = databasePath.isEmpty ? ":memory:" : databasePath
      guard let databaseURL = URL(string: databasePath)
      else {
        struct InvalidDatabasePath: Error {}
        throw InvalidDatabasePath()
      }
      guard !databaseURL.isInMemory
      else {
        return URL(string: "file:\(String.sqliteDataCloudKitSchemaName)?mode=memory&cache=shared")!
      }
      return
        databaseURL.deletingLastPathComponent().appending(
          component: ".\(databaseURL.deletingPathExtension().lastPathComponent)"
        )
        .appendingPathExtension("metadata\(containerIdentifier.map { "-\($0)" } ?? "").sqlite")
    }

    package var isInMemory: Bool {
      path.isEmpty
        || path.hasPrefix(":memory:")
        || absoluteString.hasPrefix(":memory:")
        || URLComponents(url: self, resolvingAgainstBaseURL: false)?
          .queryItems?
          .contains(where: { $0.name == "mode" && $0.value == "memory" })
          == true
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  package struct SyncEngines {
    private let rawValue: (private: any SyncEngineProtocol, shared: any SyncEngineProtocol)?
    init() {
      rawValue = nil
    }
    init(private: any SyncEngineProtocol, shared: any SyncEngineProtocol) {
      rawValue = (`private`, shared)
    }
    var isRunning: Bool {
      rawValue != nil
    }
    package var `private`: (any SyncEngineProtocol)? {
      guard let `private` = rawValue?.private
      else {
        if isRunning {
          reportIssue("Private sync engine has not been set.")
        }
        return nil
      }
      return `private`
    }
    package var `shared`: (any SyncEngineProtocol)? {
      guard let `shared` = rawValue?.shared
      else {
        if isRunning {
          reportIssue("Shared sync engine has not been set.")
        }
        return nil
      }
      return `shared`
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension Database {
    /// Attaches the metadatabase to an existing database connection.
    ///
    /// Invoke this method when preparing your database connection in order to allow querying the
    /// ``SyncMetadata`` table (see <doc:CloudKitSync#Accessing-CloudKit-metadata> for more info):
    ///
    /// ```swift
    /// func appDatabase() -> any DatabaseWriter {
    ///   var configuration = Configuration()
    ///   configuration.prepareDatabase = { db in
    ///     db.attachMetadatabase()
    ///     …
    ///   }
    /// }
    /// ```
    ///
    /// By default this method will use the container identifier assigned in your app's
    /// entitlements. If you wish to use a different container identifier then you can provide
    /// the `containerIdentifier` argument.
    ///
    /// See <doc:PreparingDatabase> for more information on preparing your database.
    ///
    /// - Parameter containerIdentifier: The identifier of the CloudKit container used to
    /// synchronize data. Defaults to the value set in the app's entitlements.
    public func attachMetadatabase(containerIdentifier: String? = nil) throws {
      @Dependency(\.context) var context
      let containerIdentifier =
        containerIdentifier
        ?? ModelConfiguration(groupContainer: .automatic).cloudKitContainerIdentifier
        ?? (context != .live ? "container" : nil)

      guard let containerIdentifier else {
        throw SyncEngine.SchemaError.noCloudKitContainer
      }

      let databasePath = try PragmaDatabaseList.select(\.file).fetchOne(self)
      guard let databasePath else {
        struct PathError: Error {}
        throw SyncEngine.SchemaError(
          reason: .unknown,
          debugDescription: """
            Expected to load a database path from the connection, but failed to do so.
            """
        )
      }
      let url = try URL.metadatabase(
        databasePath: databasePath,
        containerIdentifier: containerIdentifier
      )
      let path = url.isInMemory ? url.absoluteString : url.path(percentEncoded: false)
      let database: any DatabaseWriter =
        url.isInMemory
        ? try DatabaseQueue(path: path)
        : try DatabasePool(path: path)
      _ = try database.read { db in
        try #sql("SELECT 1").execute(db)
      }
      try #sql(
        """
        ATTACH DATABASE \(bind: path) AS \(quote: .sqliteDataCloudKitSchemaName)
        """
      )
      .execute(self)
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension SyncEngine {
    package struct SchemaError: LocalizedError {
      package enum Reason {
        case cycleDetected
        case invalidForeignKey(ForeignKey)
        case invalidForeignKeyAction(ForeignKey)
        case invalidTableName(String)
        case metadatabaseMismatch(attachedPath: String, syncEngineConfiguredPath: String)
        case noCloudKitContainer
        case nonNullColumnsWithoutDefault(tableName: String, columnNames: [String])
        case unknown
        case uniquenessConstraint
      }
      package let reason: Reason
      package let debugDescription: String

      package var errorDescription: String? {
        "Could not synchronize data with iCloud."
      }

      static let noCloudKitContainer = Self(
        reason: .noCloudKitContainer,
        debugDescription: """
          No default CloudKit container found. Make sure to enable iCloud entitlements in your \
          app's "Signing & Capabilities" and add a container identifier.
          """
      )
    }

    fileprivate func validateSchema() throws {
      let tableNames = Set(tables.map { $0.base.tableName })
      for tableName in tableNames {
        if tableName.contains(":") {
          throw SyncEngine.SchemaError(
            reason: .invalidTableName(tableName),
            debugDescription: "Table name contains invalid character ':'"
          )
        }
      }
      try userDatabase.read { db in
        for (tableName, foreignKeys) in foreignKeysByTableName {
          let invalidForeignKey = foreignKeys.first(where: { tablesByName[$0.table] == nil })
          if let invalidForeignKey {
            throw SyncEngine.SchemaError(
              reason: .invalidForeignKey(invalidForeignKey),
              debugDescription: """
                Foreign key \
                \(tableName.debugDescription).\(invalidForeignKey.from.debugDescription) \
                references table \(invalidForeignKey.table.debugDescription) that is not \
                synchronized. Update 'SyncEngine.init' to synchronize \
                \(invalidForeignKey.table.debugDescription). 
                """
            )
          }

          if foreignKeys.count == 1,
            let foreignKey = foreignKeys.first,
            [.restrict, .noAction].contains(foreignKey.onDelete)
          {
            throw SyncEngine.SchemaError(
              reason: .invalidForeignKeyAction(foreignKey),
              debugDescription: """
                Foreign key \(tableName.debugDescription).\(foreignKey.from.debugDescription) \
                action not supported. Must be 'CASCADE', 'SET DEFAULT' or 'SET NULL'.
                """
            )
          }
        }

        for table in tables {
          func open<T>(_: some SynchronizableTable<T>) throws {
            let columnsWithUniqueConstraints = try PragmaIndexList<T>
              .where { $0.isUnique && $0.origin.neq("pk") }
              .select(\.name)
              .fetchAll(db)
            if !columnsWithUniqueConstraints.isEmpty {
              throw SyncEngine.SchemaError(
                reason: .uniquenessConstraint,
                debugDescription: """
                  Uniqueness constraints are not supported for synchronized tables.
                  """
              )
            }
          }
          try open(table)
        }
      }
    }
  }

  package protocol SynchronizableTable<Base>: Hashable, Sendable {
    associatedtype Base: PrimaryKeyedTable & _SendableMetatype
    where
      Base.PrimaryKey.QueryOutput: IdentifierStringConvertible,
      Base.TableColumns.PrimaryColumn: WritableTableColumnExpression
    var base: Base.Type { get }
  }

  package struct SynchronizedTable<
    Base: PrimaryKeyedTable & _SendableMetatype
  >: SynchronizableTable
  where
    Base.PrimaryKey.QueryOutput: IdentifierStringConvertible,
    Base.TableColumns.PrimaryColumn: WritableTableColumnExpression
  {
    package init(for table: Base.Type = Base.self) {}
    package var base: Base.Type { Base.self }
  }

  private struct HashableSynchronizedTable: Hashable {
    let type: any SynchronizableTable
    init(_ type: any SynchronizableTable) {
      self.type = type
    }
    func hash(into hasher: inout Hasher) {
      hasher.combine(ObjectIdentifier(type.base))
    }
    static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.type.base == rhs.type.base
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private func tablesByOrder(
    userDatabase: UserDatabase,
    tables: [any SynchronizableTable],
    tablesByName: [String: any SynchronizableTable]
  ) throws -> [String: Int] {
    let tableDependencies = try userDatabase.read { db in
      var dependencies: OrderedDictionary<HashableSynchronizedTable, [any SynchronizableTable]> =
        [:]
      for table in tables {
        func open<T>(_: some SynchronizableTable<T>) throws -> [String] {
          try PragmaForeignKeyList<T>
            .order(by: \.table)
            .select(\.table)
            .fetchAll(db)
        }
        let toTables = try open(table)
        for toTable in toTables {
          guard let toTableType = tablesByName[toTable]
          else { continue }
          dependencies[HashableSynchronizedTable(table), default: []].append(toTableType)
        }
      }
      return dependencies
    }

    var visited = Set<HashableSynchronizedTable>()
    var marked = Set<HashableSynchronizedTable>()
    var result: [String: Int] = [:]
    for table in tableDependencies.keys {
      try visit(table: table)
    }
    return result

    func visit(table: HashableSynchronizedTable) throws {
      guard !visited.contains(table)
      else { return }
      guard !marked.contains(table)
      else {
        throw SyncEngine.SchemaError(
          reason: .cycleDetected,
          debugDescription: """
            Cycles are not currently permitted in schemas, e.g. a table that references itself.
            """
        )
      }

      marked.insert(table)
      for dependency in tableDependencies[table] ?? [] {
        try visit(table: HashableSynchronizedTable(dependency))
      }
      marked.remove(table)
      visited.insert(table)
      result[table.type.base.tableName] = result.count
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  extension Updates<SyncMetadata> {
    mutating func setLastKnownServerRecord(_ lastKnownServerRecord: CKRecord?) {
      self.zoneName = lastKnownServerRecord?.recordID.zoneID.zoneName ?? self.zoneName
      self.ownerName = lastKnownServerRecord?.recordID.zoneID.ownerName ?? self.ownerName
      self.lastKnownServerRecord = #bind(lastKnownServerRecord)
      self._lastKnownServerRecordAllFields = #bind(lastKnownServerRecord)
      if let lastKnownServerRecord {
        self.userModificationTime = #sql(
          """
          max(\(self.userModificationTime), \(lastKnownServerRecord.userModificationTime))
          """
        )
      }
    }
  }

  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  private func upsert<T>(
    _: some SynchronizableTable<T>,
    record: CKRecord,
    columnNames: some Collection<String>
  ) throws -> QueryFragment {
    let setColumnNames = T.TableColumns.writableColumns.map(\.name)
      .filter { record.hasSet(key: $0) }
    guard !setColumnNames.isEmpty
    else {
      return ""
    }
    let columnNames = columnNames.filter { setColumnNames.contains($0) }
    let hasNonPrimaryKeyColumns = columnNames.contains { $0 != T.primaryKey.name }
    var query: QueryFragment = "INSERT INTO \(T.self) ("
    query.append(setColumnNames.map { "\(quote: $0)" }.joined(separator: ", "))
    query.append(") VALUES (")
    query.append(
      try setColumnNames
        .map { columnName in
          if let asset = record[columnName] as? CKAsset {
            @Dependency(\.dataManager) var dataManager
            guard let url = asset.fileURL else {
              throw SyncEngine.FetchCompletionError.invalidRecord(record.recordID)
            }
            return try dataManager.load(url).queryFragment
          } else {
            return record.encryptedValues[columnName]?.queryFragment ?? "NULL"
          }
        }
        .joined(separator: ", ")
    )
    query.append(") ON CONFLICT(\(quote: T.primaryKey.name)) DO")
    if hasNonPrimaryKeyColumns {
      query.append(" UPDATE SET ")
      query.append(
        columnNames
          .filter { $0 != T.primaryKey.name }
          .map {
            """
            \(quote: $0) = "excluded".\(quote: $0)
            """
          }
          .joined(separator: ", ")
      )
    } else {
      query.append(" NOTHING")
    }
    return query
  }

  @TaskLocal package var _isSynchronizingChanges = false
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @TaskLocal package var _currentZoneID: CKRecordZone.ID?
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @DatabaseFunction("sqlitedata_icloud_currentZoneName")
  func currentZoneName() -> String? {
    _currentZoneID?.zoneName
  }
  @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
  @DatabaseFunction("sqlitedata_icloud_currentOwnerName")
  func currentOwnerName() -> String? {
    _currentZoneID?.ownerName
  }

  private struct ActivityCounts {
    var sendingChangesCount = 0
    var fetchingChangesCount = 0
  }

  #if DEBUG
    @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
    private struct NextRecordZoneChangeBatchLoggingState {
      var events: [String] = []
      var recordTypes: [String] = []
      var recordNames: [String] = []
      var tabularDescription: String? {
        guard !events.isEmpty
        else { return nil }
        var dataFrame: DataFrame = [
          "event": events,
          "recordType": recordTypes,
          "recordName": recordNames,
        ]
        dataFrame.sort(
          on: ColumnID("event", String.self),
          ColumnID("recordType", String.self),
          ColumnID("recordName", String.self)
        )
        var formattingOptions = FormattingOptions(
          maximumLineWidth: 120,
          maximumCellWidth: 80,
          maximumRowCount: 50,
          includesColumnTypes: false
        )
        formattingOptions.includesRowAndColumnCounts = false
        formattingOptions.includesRowIndices = false
        return
          dataFrame
          .description(options: formattingOptions)
          .replacing("\n", with: "\n  ")
      }
    }
  #endif
#endif
