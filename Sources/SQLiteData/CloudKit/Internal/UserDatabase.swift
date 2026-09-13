#if canImport(CloudKit)
  import Dependencies
  package import GRDB

  package struct UserDatabase {
    package let database: any DatabaseWriter
    package init(database: any DatabaseWriter) {
      self.database = database
    }

    var path: String {
      database.path
    }

    var configuration: Configuration {
      database.configuration
    }

    package func write<T: Sendable>(
      _ updates: @Sendable (Database) throws -> T
    ) async throws -> T {
      let token = SyncWorkContext.token
      return try await database.write { db in
        try token?.check()
        let result = try $_isSynchronizingChanges.withValue(true) { try updates(db) }
        try token?.check()
        return result
      }
    }

    package func read<T: Sendable>(
      _ updates: @Sendable (Database) throws -> T
    ) async throws -> T {
      try await database.read { db in
        try updates(db)
      }
    }

    @_disfavoredOverload
    package func write<T>(
      _ updates: (Database) throws -> T
    ) throws -> T {
      let token = SyncWorkContext.token
      return try database.write { db in
        try token?.check()
        let result = try $_isSynchronizingChanges.withValue(true) { try updates(db) }
        try token?.check()
        return result
      }
    }

    @_disfavoredOverload
    package func read<T>(
      _ updates: (Database) throws -> T
    ) throws -> T {
      try database.read { db in
        try updates(db)
      }
    }
  }
#endif
