# RethinkDB ORM for Crystal Lang

[![Build Status](https://travis-ci.org/spider-gazelle/rethinkdb-orm.svg?branch=master)](https://travis-ci.org/spider-gazelle/rethinkdb-orm)

Extending [ActiveModel](https://github.com/spider-gazelle/active-model) for attribute definitions, callbacks and validations

- [RethinkDB ORM for Crystal Lang](#rethinkdb-orm-for-crystal-lang)
  - [Callbacks](#callbacks)
  - [Associations](#associations)
    - [`belongs_to`](#belongsto)
    - [`has_many`](#hasmany)
    - [`has_one`](#hasone)
    - [Dependency](#dependency)
  - [Indexes](#indexes)
  - [Changefeeds](#changefeeds)
  - [Validations](#validations)
    - [`ensure_unique`](#ensureunique)
  - [Timestamps](#timestamps)

## Configuration

```crystal
# Below is the list of settings exposed by RethinkORM and their defaults
RethinkORM::Settings.configure do |settings|
  settings.host = ENV["RETHINKDB_HOST"]? || "localhost"
  settings.port = (ENV["RETHINKDB_PORT"]? || 28015).to_i
  settings.db = ENV["RETHINKDB_DB"]? || ENV["RETHINKDB_DATABASE"]? || "test"
  settings.user = ENV["RETHINKDB_USER"]? || "admin"
  settings.password = ENV["RETHINKDB_PASSWORD"]? || ""
  settings.retry_interval = (ENV["RETHINKDB_TIMEOUT"]? || 2).to_i.seconds
  settings.retry_attempts = ENV["RETHINKDB_RETRIES"]?.try &.to_i
  settings.lock_expire = (ENV["RETHINKDB_LOCK_EXPIRE"]? || 30).to_i.seconds
  settings.lock_timeout = (ENV["RETHINKDB_LOCK_TIMEOUT"]? || 5).to_i.seconds
end
```

## Callbacks

Register callbacks for `save`, `update`, `create` and `destroy` by setting the corresponding before/after callback handler.

```crystal
class ModelWithCallbacks < RethinkORM::Base
  attribute address : String
  attribute age : Int32 = 10

  before_create :set_address
  after_update :set_age
  before_destroy do
    self.name = "joe"
  end

  def set_address
    self.address = "23"
  end

  def set_age
    self.age = 30
  end
end
```

## Associations

Set associations with `belongs_to`, `has_many` and `has_one`.

Access children in parent by accessing the method correpsonding to the pluralised child. Children collection method name is generated by dumb pluralisation (appending an s). Optionally set children collection name in `has_many` by setting `collection_name` param.

The `has_many` association requires the `belongs_to` association on the child. By default, `belongs_to` creates a secondary index on the foreign key.

```crystal
class Parent < RethinkORM::Base
  attribute name : String
  has_many Child, collection_name: "children"
end

class Child < RethinkORM::Base
  attribute age : Int32
  belongs_to Parent
  has_many Pet
end

class Pet < RethinkORM::Base
  attribute name : String
  belongs_to Child
end

parent = Parent.new(name: "Phil")
parent.children.empty? # => true

child = Child.new(age: 99)
child.pets.empty? # => true
```

### `belongs_to`

Parameter      |                                                               | Default
-------------- | ------------------------------------------------------------- | -------
`parent_class` | The parent class who this class is dependent on               |
`dependent`    | Sets destroy behaviour. One of `:none`, `:destroy`, `:delete` | `:none`
`create_index` | Create a secondary index on the foreign key                   | `true`

### `has_many`

Parameter         |                                                                               | Default
----------------- | ----------------------------------------------------------------------------- | -------
`child_class`     | The parent class who this class is dependent on                               |
`dependent`       | Sets destroy behaviour. One of `:none`, `:destroy`, `:delete`                 | `:none`
`collection_name` | Define collection name, otherwise collection named through dumb pluralisation | `nil`

### `has_one`

Parameter         |                                                                               | Default
----------------- | ----------------------------------------------------------------------------- | -------
`child_class`     | The parent class who this class is dependent on                               |
`dependent`       | Sets destroy behaviour. One of `:none`, `:destroy`, `:delete`                 | `:none`
`collection_name` | Define collection name, otherwise collection named through dumb pluralisation | `nil`

### Dependency

`dependent` param in the association definition macros defines the fate of the association on model destruction.<br>
Default is `:none`, `:destroy` and `:delete` ensure destruction of association dependents.

## Indexes

Set secondary indexes with `secondary_index`

Parameter   |                                               |
----------- | --------------------------------------------- |
`attribute` | defines the field on which to create an index |

## Changefeeds

Access the changefeed of a document or table through the `changes` query.<br>
Defaults to watch for events on a table if no id provided.

Parameter |                                     | Default
--------- | ----------------------------------- | -------
`id`      | id of document to watch for changes | nil

Returns an iterator that emits `NamedTuple(value: T, event: Event)`<br>

- `Changefeed::Event::Deleted` events yield the deleted model
- `Changefeed::Event::Created` events yield the created model
- `Changefeed::Event::Updated` events yield the updated model

```crystal
class Game < RethinkORM::Base
  attribute type : String
  attribute score : Int32, default: 0
end

ballgame = Game.create!(type: "footy")

# Observe changes on a single document
spawn do
  Game.changes(ballgame.id).each do |change|
    game = change[:value]
    puts "looks like the score is #{game.score}" unless game.nil?
  end
end

# Observe changes on a table
spawn do
  Game.changes.each do |change|
    game = change[:value]
    puts "#{game.type}: #{game.score}" unless game.nil?
    puts "game event: #{change[:event]}"
  end
end
```

## Validations

Builds on [active-model's validation](https://github.com/spider-gazelle/active-model#validations)

### `ensure_unique`

Fails to validate if field with duplicate value present in db.
If scope is set, the callback/block signature must be a tuple with types matching that of the scope.
The field(s) are set with the result of the transform block upon successful validation

Parameter               |                                                         | Default
----------------------- | ------------------------------------------------------- | -------
`field`                 | Model attribute on which to guarantee uniqueness        |
`scope`                 | Attributes passed to the transform, defaults to :field  | nil
`create_index`          | Whether or not to generate a secondary index            | true
`callback : T -> T`     | Optional function to transform field value              | nil
`block : T -> T`        | Optional block to transform field value before querying | nil


## Timestamps

Adds creates `created_at` and `updated_at` attributes.
- `updated_at` is set through the `before_update` callback, and initially set in the `before_save` callback.
- `created_at` is set through the `before_create` callback.

The generated timestamp is UTC.

```crystal
class Timo < RethinkORM::Base
  # Simply include the module
  include RethinkORM::Timestamps

  attribute name : String
end
```
