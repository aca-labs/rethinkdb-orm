require "rethinkdb"

module RethinkORM
  class Collection(T)
    include Iterator(T)
    include Iterator::IteratorWrapper

    @iterator : Iterator(RethinkDB::QueryResult)

    def initialize(iterator : Iterator(RethinkDB::QueryResult) | RethinkDB::QueryResult)
      @iterator = iterator.is_a?(Iterator) ? iterator : iterator.as_a.each
    end

    @atom_response : Iterator(T)? = nil

    def next
      result = if (iter = @atom_response)
                 iter.next
               else
                 wrapped_next
               end

      if result == Iterator::Stop::INSTANCE
        stop
      elsif result.is_a?(T)
        result
      else
        begin
          T.from_trusted_json result.as(RethinkDB::QueryResult).to_json
        rescue e : JSON::SerializableError
          if e.message.try &.includes?("Expected BeginObject but was BeginArray")
            atom_iterator = result.as(RethinkDB::QueryResult)
              .as_a
              .map(&.to_json)
              .map(&->T.from_trusted_json(String))
              .each

            @atom_response = atom_iterator

            atom_iterator.next
          else
            raise e
          end
        end
      end
    end

    def stop
      @iterator.stop
      super
    end
  end
end
