module RethinkORM::Associations
  # define getter and setter for parent relationship
  macro belongs_to(model_name, class_name = nil)
    {{ parent_name = class_name ? class_name.id.underscore.gsub(/::/, "_") : model_name.id }}
    {{ parent_class = class_name ? class_name.id : model_name.id.camelcase }}
    attribute {{ parent_name.id }}_id : String

    # retrieve the parent relationship
    def {{ model_name.id }}
      if parent = {{ parent_class }}.find {{ parent_name.id }}_id
        parent
      else
        {{ parent_class }}.new
      end
    end

    # set the parent relationship
    def {{model_name.id}}=(parent)
      @{{ parent_name.id }}_id = parent._id
    end
  end

  macro has_many(children_collection, class_name = nil)
    def {{children_collection.id}}
      {% children_class = class_name ? class_name.id : children_collection.id[0...-1].camelcase %}
      return [] of {{children_class}} unless self._id
      {{children_class}}.all({"#{self.class.to_s.underscore.gsub(/::/,"_")}_id" => self._id})
    end
  end
end
