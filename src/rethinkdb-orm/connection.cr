require "future"
require "habitat"
require "mutex"
require "rethinkdb"

require "./error"
require "./settings"

module RethinkDB
  class Connection
    def closed?
      sock.closed?
    end
  end
end

module RethinkORM
  class Connection
    extend Settings

    private alias R = RethinkDB

    Log = ::Log.for(self)

    @@resource_check = false
    @@resource_lock = Mutex.new
    @@db : RethinkDB::Connection? = nil

    def self.db
      @@resource_lock.synchronize {
        connection = @@db
        return connection if @@resource_check && connection && !connection.closed?

        begin
          connection = Retriable.retry(
            max_attempts: settings.retry_attempts,
            on: Socket::ConnectError,
            on_retry: ->(_e : Exception, attempt : Int32, _t : Time::Span, _i : Time::Span) {
              Log.warn { "attempt #{attempt} connecting to #{settings.host}:#{settings.port}" }
            }
          ) do
            RethinkDB::Connection.new(
              host: settings.host,
              port: settings.port,
              db: settings.db,
              user: settings.user,
              password: settings.password,
              max_retry_interval: settings.retry_interval,
              max_retry_attempts: settings.retry_attempts,
            )
          end
        rescue e : Socket::ConnectError
          raise Error::ConnectError.new("failed to connect to #{settings.host}:#{settings.port} after #{settings.retry_attempts} retries")
        end

        @@db = connection

        ensure_resources!(connection)

        connection
      }
    end

    # Passes the query builder to the block.
    #
    # Auto creates the database if its not already present.
    # The block defined query is run and raw results returned.
    def self.raw(**options)
      query = yield R
      Retriable.retry(
        max_attempts: settings.query_retries,
        on: IO::Error,
        on_retry: ->(_e : Exception, attempt : Int32, _t : Time::Span, _i : Time::Span) {
          Log.warn { "attempt #{attempt} retrying query" }
        }
      ) do
        query.run(self.db, **options)
      end
    end

    # Passes query builder and datum term of supplied raw json string
    #
    def self.raw_json(json : String, **options)
      raw(**options) do |q|
        yield q, q.json(json)
      end
    end

    # Lazily check for and create non-existant resources in rethink
    #
    # TODO: support more configuration for db/table sharding and replication
    protected def self.ensure_resources!(connection)
      return if @@resource_check

      tables = RethinkORM::Base::TABLES.uniq
      indices = RethinkORM::Base::INDICES.uniq

      # Generate db creation query
      db_check = create_database_query

      # Generate index creation query
      index_queries = create_index_queries(indices)

      # Combine table and index queries
      table_queries = tables.map do |table|
        {table, create_table_query(table), index_queries[table]?}
      end

      # Create DB
      db_check.run(connection)

      # Create tables and indexes
      table_queries = table_queries.map do |table, table_creation, index_creation|
        future {
          begin
            table_creation.run(connection)
          rescue e : RethinkDB::ReqlOpFailedError
            raise e unless e.message.try &.includes?("already exists")
          end

          fix_duplicate_table_query(table).run(connection)

          index_creation.try &.map do |create, wait|
            begin
              create.run(connection)
            rescue e : RethinkDB::ReqlOpFailedError
              # Ignore index already exists error
              raise e unless e.message.try &.includes?("already exists")
            end

            future { wait.run(connection) }
          end.each(&.get)
        }
      end

      table_queries.each(&.get)

      # TODO: Error check
      @@resource_check = true
    end

    # Generate a DB creation query
    #
    protected def self.create_database_query(database = settings.db)
      R.branch(
        # If database present
        R.db_list.contains(database),
        # Then noop
        {"dbs_created" => 0},
        # Else create db
        R.db_create(database),
      )
    end

    # Generate a mapping { table => [{index_creation_query, index_existence_query}] }
    #
    protected def self.create_index_queries(indices, database = settings.db)
      # Group index queries by table
      indices.group_by(&.[:table]).transform_values do |queries|
        queries.map do |index|
          table = index[:table]
          field = index[:field]

          # Create index or noop
          creation = R.branch(
            # If index present
            R.db(database).table(table).index_list.contains(field),
            # Then noop
            {"created" => 0},
            # Else create index
            R.db(database).table(table).index_create(field),
          )
          # Wait for index to be ready
          existence = R.db(database).table(table).index_wait(field)

          {creation, existence}
        end
      end
    end

    # Genereate a table creation query
    #
    protected def self.create_table_query(table, database = settings.db)
      R
        .db(database)
        .table_create(table)
    end

    # Remove duplicates of a table from RethinkDB system table
    # NOTE: Necessary as multiple writers can cause duplicate tables
    protected def self.fix_duplicate_table_query(table, database = settings.db)
      R
        .db("rethinkdb")
        .table("table_config")
        .filter({db: database, name: table})
        .order_by("id")
        .slice(1)
        .delete
    end
  end
end
