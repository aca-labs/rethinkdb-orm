require "digest/sha1"
require "rethinkdb"

require "./base"
require "./settings"
require "./utils/id_generator"

include RethinkDB::Shortcuts

module RethinkORM
  # DB locks for RethinkDB
  # TODO: Conform to the [NoBrainer](http://nobrainer.io/) locking interface.
  class Lock < Base
    extend Settings

    # NOTE: Need a different tablename? inherit or reopen the class.
    table "locks"

    # TODO: set to `key_hash` when primary_key supported
    attribute id : String?

    # Key is not an index, PKs are 127 chars.
    attribute key : String

    attribute instance_token : String, converter: ::RethinkORM::Lock::TokenRefresher

    attribute expires_at : Time, converter: ::RethinkORM::Lock::FloatEpochConverter

    secondary_index key
    secondary_index instance_token
    secondary_index expires_at

    validates :key, presence: true

    # Seconds before the lock expires
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    property expire : Time::Span = Lock.settings.lock_expire

    # Lock acquisition timeout
    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    property timeout : Time::Span = Lock.settings.lock_timeout

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    getter? locked : Bool = false

    # Returns all expired locks
    #
    def self.expired
      Lock.where do |d|
        r.epoch_time(d[:expires_at]) < r.now
      end
    end

    # Hash a key
    #
    def self.find(key)
      super(Digest::SHA1.base64digest(key.to_s))
    end

    # Reset instance token if it's loaded and expired?
    def initialize(
      key : String,
      expire : Time::Span? = nil,
      timeout : Time::Span? = nil,
      instance_token : String = Lock.new_instance_token
    )
      @key = key
      @id = Digest::SHA1.base64digest(key)
      @instance_token = instance_token
      @expire = expire if expire
      @timeout = timeout if timeout
    end

    def synchronize(**options)
      lock(**options)
      begin
        yield
      ensure
        unlock if locked?
      end
    end

    def lock(expire : Time::Span = self.expire, timeout : Time::Span = self.timeout)
      sleep_amount = 0.1.seconds
      start_at = Time.utc
      loop do
        return if try_lock(expire: expire)

        raise Error::LockUnavailable.new(key.as(String)) if Time.utc - start_at + sleep_amount > timeout
        sleep(sleep_amount)

        sleep_amount = {1.seconds, sleep_amount * 2}.min
      end
    end

    def try_lock(expire : Time::Span = self.expire)
      raise Error::LockInvalidOp.new(locked: locked?, key: key.as(String)) if locked?

      set_expiration(expire)

      result = Lock.table_query do |q|
        q.get(self.id).replace do |doc|
          r.branch(
            # If lock expired
            doc.eq(nil).or(r.epoch_time(doc[:expires_at]) < r.now),
            # Replace lock
            lock_attributes,
            # Otherwise, leave existing lock
            doc
          )
        end
      end

      inserted = result["inserted"]?.try &.raw.as(Int64)
      replaced = result["replaced"]?.try &.raw.as(Int64)

      @locked = if inserted && replaced
                  inserted + replaced == 1
                else
                  false
                end
    end

    def unlock
      raise Error::LockInvalidOp.new(locked: locked?, key: key.as(String)) unless locked?

      result = Lock.table_query do |q|
        q.get(self.id).replace do |doc|
          r.branch(
            # If instance token matches
            doc[:instance_token].default(nil).eq(self.instance_token),
            # Delete the lock
            nil,
            # Otherwise leave it
            doc
          )
        end
      end

      @locked = false
      raise Error::LockLost.new(key.as(String)) unless result["deleted"] == 1
    end

    def refresh(expire : Time::Span? = nil)
      raise Error::LockInvalidOp.new(locked: locked?, key: key.as(String)) unless locked?

      set_expiration(expire, use_previous: true)

      result = Lock.table_query do |q|
        q.get(self.id).update do |doc|
          r.branch(
            # If token is current instance token
            doc[:instance_token].eq(self.instance_token),
            # Then update expires
            {:expires_at => expiry_epoch},
            # Otherwise return nil
            nil
          )
        end
      end

      # NOTE: Due to the crappy 1 second resolution of If we are too quick, expires_at may not change, and the returned
      # "replaced" won't be 1. We'll generate a spurious error. This is very
      # unlikely to happen and should not harmful.
      unless result["replaced"] == 1
        @locked = false
        raise Error::LockLost.new(key.as(String))
      end
    end

    @[JSON::Field(ignore: true)]
    @[YAML::Field(ignore: true)]
    @previous_expire : Time::Span? = nil

    private def set_expiration(expire : Time::Span? = nil, use_previous : Bool = false)
      expire = @previous_expire if !expire && use_previous
      # Default to configured expiration
      expire ||= Lock.settings.lock_expire
      @previous_expire = expire
      self.expires_at = Time.utc + expire
    end

    protected def expiry_epoch
      self.expires_at.as(Time).to_unix_ms / 1000
    end

    protected def lock_attributes
      {
        :id             => @id,
        :key            => @key,
        :instance_token => @instance_token,
        :expires_at     => expiry_epoch,
      }
    end

    protected def self.new_instance_token
      IdGenerator.next({{@type}}.table_name)
    end

    {% for method in {:save, :save!, :update, :update!, :destroy, :delete} %}
      protected def {{method.id}}(**args)
        raise NotImplementedError.new("{{method.id}} not implemented")
      end
    {% end %}

    # NOTE: Necessary as overriding `from_trusted_json` wasn't working
    #
    # :nodoc:
    module TokenRefresher
      def self.from_json(value : JSON::PullParser) : String
        value.read_string # Just pull the string, and ignore it.
        Lock.new_instance_token
      end

      def self.to_json(value : String, json : JSON::Builder)
        json.string(value)
      end
    end

    # This module converts an epoch to a decimal seconds.
    # RethinkDB's epochs are floats!?
    #
    # :nodoc:
    module FloatEpochConverter
      def self.from_json(value : JSON::PullParser) : Time
        float_milliseconds = value.read_float * 1000
        Time.unix_ms(float_milliseconds.to_i64)
      end

      def self.to_json(value : Time, json : JSON::Builder)
        json.float(value.to_unix_ms/1000)
      end
    end
  end
end

require "./lock/reentrant"
