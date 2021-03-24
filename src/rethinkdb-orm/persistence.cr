require "rethinkdb"

require "./connection"
require "./utils/id_generator"

module RethinkORM::Persistence
  # Flag to allow lazy querying of table status
  @@table_created = false

  # :nodoc:
  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  property _new_flag = false

  # Id generated on save or set on load
  def new_record?
    if destroyed?
      false
    else
      id_local = @id
      _new_flag || id_local.nil? || id_local.try &.empty?
    end
  end

  def persisted?
    !(new_record? || destroyed?)
  end

  @[JSON::Field(ignore: true)]
  @[YAML::Field(ignore: true)]
  property? destroyed : Bool = false

  macro included

    # Set the uuid generator for models
    @@uuid_generator = IdGenerator

    # Allow user defined uuid generator
    def uuid_generator=(generator : Class)
      @@uuid_generator = generator
    end

    # Creates the model.
    #
    # See `#save!`
    def self.create!(**attributes)
      new(**attributes).save!
    end

    # Creates the model.
    #
    # Persistence can be confirmed via `#persisted?`
    def self.create(**attributes)
      document = new(**attributes)
      begin
        document.save!
      end
      document
    end

    # Removes all records from the table
    #
    def self.clear
      Connection.raw do |q|
        q.table(@@table_name).delete
      end
    end
  end

  # Saves the model.
  #
  # If the model is new, a record gets created in the database, otherwise
  # the existing record gets updated.
  def save(**options)
    save!(**options)
    true
  rescue RethinkORM::Error
    false
  end

  # Saves the model.
  #
  # If the model is new, a record gets created in the database, otherwise
  # the existing record gets updated.
  #
  # Raises
  # - `RethinkORM::Error:DocumentNotSaved` if was document was destroyed before save
  # - `RethinkORM::Error:DocumentNotSaved` if was document was not saved by RethinkDB
  # - `RethinkORM::Error:DocumentInvalid` on validation failures
  def save!(**options)
    raise RethinkORM::Error::DocumentNotSaved.new("Cannot save a destroyed document!") if destroyed?
    new_record? ? __create(**options) : __update(**options)
  end

  # Updates the model
  #
  # Non-atomic updates are required for multidocument updates
  def update(**attributes)
    update!(**attributes)
    true
  rescue RethinkORM::Error
    false
  end

  # Updates the model in place
  #
  # Raises `RethinkORM::Error::DocumentInvalid` on update failure
  def update!(**attributes)
    assign_attributes(**attributes)
    save!
  end

  # Atomically update specified fields, without running callbacks
  #
  def update_fields(**attributes)
    raise RethinkORM::Error::DocumentNotSaved.new("Cannot update fields of a new document!") if new_record?

    assign_attributes(**attributes)
    update_body = subset_json(attributes.keys)

    response = Connection.raw_json(update_body) do |q, doc|
      q.table(@@table_name)
        .get(@id)
        .update(doc)
    end

    replaced = response["replaced"]?.try(&.as_i?) || 0
    updated = response["updated"]?.try(&.as_i?) || 0
    clear_changes_information if replaced > 0 || updated > 0
    self
  end

  # Destroy object, run destroy callbacks and update associations
  #
  def destroy
    return self if destroyed?
    return self if new_record?

    run_destroy_callbacks do
      __delete
      self
    end
  end

  # Only deletes document from table. No callbacks or updated associations
  #
  def delete
    return self if destroyed?
    return self if new_record?

    __delete
  end

  # Reload the model in place.
  #
  # Raises
  # - `RethinkORM::Error::DocumentNotSaved` if document was not previously persisted
  # - `RethinkORM::Error::DocumentNotFound` if document fails to load
  def reload!
    raise RethinkORM::Error::DocumentNotSaved.new("Cannot reload unpersisted document") unless persisted?

    found = self.class.table_query &.get(self.id)
    raise RethinkORM::Error::DocumentNotFound.new("Key not present: #{id}") if found.raw.nil?

    assign_attributes_from_trusted_json(found.to_json)

    clear_changes_information
    reset_associations

    self
  end

  # Serialization of a subset of the model's attributes.
  #
  # FIXME: Optimise
  protected def subset_json(fields : Enumerable(String) | Enumerable(Symbol))
    string_keys = fields.is_a?(Enumerable(String)) ? fields : fields.map(&.to_s)
    JSON.parse(self.to_json).as_h.select!(string_keys).to_json
  end

  # Internal update function, runs callbacks and pushes update to RethinkDB
  #
  private def __update(**options)
    return self unless changed?

    run_update_callbacks do
      run_save_callbacks do
        raise RethinkORM::Error::DocumentInvalid.new(self) unless valid?

        response = Connection.raw_json(self.to_json) do |q, doc|
          q.table(@@table_name)
            .get(@id)
            .update(doc, **options)
        end

        # TODO: Extend active-model to include previous changes
        # TODO: Update associations
        replaced = response["replaced"]?.try(&.as_i?) || 0
        updated = response["updated"]?.try(&.as_i?) || 0
        unchanged = response["unchanged"]?.try(&.as_i?) || 0
        created = response["created"]?.try(&.as_i?) || 0
        success = replaced > 0 || created > 0 || updated > 0 || unchanged == 1

        raise RethinkORM::Error::DocumentNotSaved.new("Failed to update document") unless success

        clear_changes_information
        self
      end
    end
  end

  # Internal create function, runs callbacks and pushes new model to RethinkDB
  #
  private def __create(**options)
    run_create_callbacks do
      run_save_callbacks do
        raise RethinkORM::Error::DocumentInvalid.new(self) unless valid?

        # TODO: Allow user to tag an attribute as primary key.
        #       Requires either changing default primary key or using secondary index
        @id = @@uuid_generator.next(self) if @id.presence.nil?

        response = Connection.raw_json(self.to_json) do |q, doc|
          q.table(@@table_name).insert(doc, **options)
        end

        # Set primary key if receiveing generated_key
        @id ||= response["generated_keys"]?.try(&.[0]?).try(&.to_s)

        success = (response["inserted"]?.try(&.as_i?) || 0) > 0

        raise RethinkORM::Error::DocumentNotSaved.new("Failed to create document") unless success

        clear_changes_information
        self._new_flag = false
        self
      end
    end
  end

  # Delete document in table, update model metadata
  #
  private def __delete
    response = Connection.raw do |q|
      q.table(@@table_name)
        .get(@id)
        .delete
    end

    deleted = response["deleted"]?.try(&.as_i?) || 0
    @destroyed = deleted > 0
    clear_changes_information if @destroyed
    @destroyed
  end
end
