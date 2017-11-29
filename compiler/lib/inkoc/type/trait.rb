# frozen_string_literal: true

module Inkoc
  module Type
    class Trait
      include Inspect
      include Predicates
      include TypeCompatibility
      include ObjectOperations
      include GenericTypeOperations

      attr_reader :name, :attributes, :required_methods, :required_traits
      attr_accessor :prototype, :type_parameters

      def initialize(
        name: Config::TRAIT_CONST,
        prototype: nil,
        type_parameters: TypeParameterTable.new
      )
        @name = name
        @prototype = prototype
        @attributes = SymbolTable.new
        @required_methods = SymbolTable.new
        @required_traits = Set.new
        @type_parameters = type_parameters
      end

      def new_instance(*)
        self
      end

      def trait?
        true
      end

      def define_required_method(block_type)
        required_methods.define(block_type.name, block_type)
      end

      def lookup_method(name)
        attributes[name].or_else { required_methods[name] }
      end

      def type_compatible?(other)
        return true if self == other

        other.is_a?(self.class) &&
          required_traits == other.required_traits &&
          required_methods == other.required_methods
      end

      def empty?
        required_methods.empty? && required_traits.empty?
      end

      def required_method_types(param_instances = [])
        params = Type::TypeParameterTable.new(type_parameters)
        params.initialize_in_order(param_instances)

        required_methods.map do |method|
          method.type.new_shallow_instance(params)
        end
      end
    end
  end
end
