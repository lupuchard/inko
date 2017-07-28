# frozen_string_literal: true

module Inkoc
  module TIR
    module Instruction
      class SetAttribute
        include Inspect

        attr_reader :register, :receiver, :name, :value, :location

        def initialize(register, receiver, name, value, location)
          @register = register
          @receiver = receiver
          @name = name
          @value = value
          @location = location
        end
      end
    end
  end
end
