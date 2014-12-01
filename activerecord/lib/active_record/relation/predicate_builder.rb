module ActiveRecord
  class PredicateBuilder # :nodoc:
    @handlers = []

    autoload :RelationHandler, 'active_record/relation/predicate_builder/relation_handler'
    autoload :ArrayHandler, 'active_record/relation/predicate_builder/array_handler'

    def initialize(klass, arel_table)
      @klass = klass
      @arel_table = arel_table
    end

    def resolve_column_aliases(hash)
      hash = hash.dup
      hash.keys.grep(Symbol) do |key|
        if klass.attribute_alias? key
          hash[klass.attribute_alias(key)] = hash.delete key
        end
      end
      hash
    end

    def build_from_hash(attributes)
      queries = []
      builder = self

      attributes.each do |key, value|
        table = arel_table

        if key.to_s.include?('.')
          table_name, column = key.to_s.split('.', 2)
          hash = attributes[table_name] || {}
          hash[column] = value
          key = table_name
          value = hash
        end

        if value.is_a?(Hash)
          if value.empty?
            queries << '1=0'
          else
            table       = Arel::Table.new(key)
            association = klass._reflect_on_association(key)
            builder = self.class.new(association && association.klass, table)

            value.each do |k, v|
              queries.concat builder.expand(k, v)
            end
          end
        else
          queries.concat builder.expand(key.to_s, value)
        end
      end

      queries
    end

    def expand(column, value)
      queries = []

      # Find the foreign key when using queries such as:
      # Post.where(author: author)
      #
      # For polymorphic relationships, find the foreign key and type:
      # PriceEstimate.where(estimate_of: treasure)
      if klass && reflection = klass._reflect_on_association(column)
        if reflection.polymorphic? && base_class = polymorphic_base_class_from_value(value)
          queries << self.class.build(arel_table[reflection.foreign_type], base_class)
        end

        column = reflection.foreign_key
      end

      queries << self.class.build(arel_table[column], value)
      queries
    end

    def polymorphic_base_class_from_value(value)
      case value
      when Relation
        value.klass.base_class
      when Array
        val = value.compact.first
        val.class.base_class if val.is_a?(Base)
      when Base
        value.class.base_class
      end
    end

    def self.references(attributes)
      attributes.map do |key, value|
        if value.is_a?(Hash)
          key
        else
          key = key.to_s
          key.split('.').first if key.include?('.')
        end
      end.compact
    end

    # Define how a class is converted to Arel nodes when passed to +where+.
    # The handler can be any object that responds to +call+, and will be used
    # for any value that +===+ the class given. For example:
    #
    #     MyCustomDateRange = Struct.new(:start, :end)
    #     handler = proc do |column, range|
    #       Arel::Nodes::Between.new(column,
    #         Arel::Nodes::And.new([range.start, range.end])
    #       )
    #     end
    #     ActiveRecord::PredicateBuilder.register_handler(MyCustomDateRange, handler)
    def self.register_handler(klass, handler)
      @handlers.unshift([klass, handler])
    end

    register_handler(BasicObject, ->(attribute, value) { attribute.eq(value) })
    # FIXME: I think we need to deprecate this behavior
    register_handler(Class, ->(attribute, value) { attribute.eq(value.name) })
    register_handler(Base, ->(attribute, value) { attribute.eq(value.id) })
    register_handler(Range, ->(attribute, value) { attribute.between(value) })
    register_handler(Relation, RelationHandler.new)
    register_handler(Array, ArrayHandler.new)

    def self.build(attribute, value)
      handler_for(value).call(attribute, value)
    end

    def self.handler_for(object)
      @handlers.detect { |klass, _| klass === object }.last
    end
    private_class_method :handler_for

    protected

    attr_reader :klass, :arel_table

  end
end
