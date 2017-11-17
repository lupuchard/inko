# frozen_string_literal: true

module Inkoc
  module Pass
    class DefineTypes
      include VisitorMethods

      DeferredMethod = Struct.new(:ast, :scope)

      attr_reader :module

      def initialize(mod, state)
        @module = mod
        @state = state
        @method_bodies = []
      end

      def diagnostics
        @state.diagnostics
      end

      def typedb
        @state.typedb
      end

      def define_type(node, scope)
        node.type = process_node(node, scope)
      end

      def define_types(nodes, scope)
        nodes.map { |node| define_type(node, scope) }
      end

      def run(ast)
        locals = ast.locals

        on_module_body(ast, locals)

        # Method bodies are processed last since they may depend on types
        # defined after the method itself is defined.
        @method_bodies.each do |method|
          process_deferred_method(method)
        end

        [ast]
      end

      def process_imports(scope)
        @module.imports.each do |node|
          process_node(node, scope)
        end
      end

      def on_module_body(ast, locals)
        @module.type =
          if @module.define_module?
            define_module_type
          else
            typedb.top_level
          end

        @module.globals.define(Config::MODULE_GLOBAL, @module.type)

        scope = TypeScope.new(@module.type, @module.body.type, locals)

        process_imports(scope)

        define_type(ast, scope)
      end

      def define_module_type
        top = typedb.top_level
        modules = top.lookup_attribute(Config::MODULES_ATTRIBUTE).type
        proto = top.lookup_attribute(Config::MODULE_TYPE).type
        type = Type::Object.new(name: @module.name.to_s, prototype: proto)

        modules.define_attribute(type.name, type)

        type
      end

      def on_import(node, _)
        name = node.qualified_name
        mod = @state.module(name)

        node.symbols.each do |import_symbol|
          process_node(import_symbol, mod)
        end
      end

      def on_import_symbol(symbol, source_mod)
        return unless symbol.expose?

        sym_name = symbol.symbol_name.name
        type = source_mod.type_of_attribute(sym_name)
        import_as = symbol.import_as(source_mod)

        unless type
          diagnostics.import_undefined_symbol_error(
            source_mod.name,
            sym_name,
            symbol.location
          )

          return
        end

        import_symbol_as_global(import_as, type, symbol.location_for_name)
      end

      def on_import_self(symbol, source_mod)
        return unless symbol.expose?

        import_as = symbol.import_as(source_mod)
        loc = symbol.location_for_name

        import_symbol_as_global(import_as, source_mod.type, loc)
      end

      def on_import_glob(symbol, source_mod)
        loc = symbol.location_for_name

        source_mod.attributes.each do |attribute|
          import_symbol_as_global(attribute.name, attribute.type, loc)
        end
      end

      def import_symbol_as_global(name, type, location)
        if @module.global_defined?(name)
          diagnostics.import_existing_symbol_error(name, location)
        else
          @module.globals.define(name, type)
        end
      end

      def on_body(node, scope)
        scope.define_self_local

        return_types = return_types_for_body(node, scope)
        first_type = return_types[0][0]

        return_types.each do |(type, location)|
          next if type.type_compatible?(first_type)

          diagnostics.type_error(first_type, type, location)
        end

        first_type
      end

      def return_types_for_body(node, scope)
        types = []
        last_type = nil

        node.expressions.each do |expr|
          type = define_type(expr, scope)

          next unless type

          location = expr.location
          last_type = [type, location]

          types.push([type, location]) if expr.return?
        end

        last_type ||= [typedb.nil_type, node.location]

        types << last_type
      end

      def on_integer(*)
        typedb.integer_type
      end

      def on_float(*)
        typedb.float_type
      end

      def on_string(*)
        typedb.string_type
      end

      def on_attribute(node, scope)
        name = node.name
        symbol = scope.self_type.lookup_attribute(name)

        if symbol.nil?
          diagnostics
            .undefined_attribute_error(scope.self_type, name, node.location)
        end

        symbol.type
      end

      def on_constant(node, scope)
        resolve_module_type(node, scope.self_type)
      end

      def on_identifier(node, scope)
        name = node.name
        loc = node.location

        rtype, block_type =
          if (local_type = scope.type_of_local(name))
            local_type
          elsif scope.self_type.responds_to_message?(name)
            send_object_message(scope.self_type, name, [], scope, loc)
          elsif @module.responds_to_message?(name)
            send_object_message(@module.type, name, [], scope, loc)
          elsif (global_type = @module.type_of_global(name))
            global_type
          else
            diagnostics.undefined_method_error(scope.self_type, name, loc)
            Type::Dynamic.new
          end

        node.block_type = block_type if block_type

        rtype.resolve_type(scope.self_type)
      end

      def on_global(node, *)
        name = node.name
        symbol = @module.globals[name]

        diagnostics.undefined_constant_error(name, node.location) if symbol.nil?

        symbol.type
      end

      def on_self(_, scope)
        scope.self_type
      end

      def on_send(node, scope)
        rtype, node.block_type = send_object_message(
          receiver_type(node, scope),
          node.name,
          node.arguments,
          scope,
          node.location
        )

        rtype
      end

      def on_keyword_argument(node, scope)
        define_type(node.value, scope)
      end

      def send_object_message(receiver, name, args, scope, location)
        arg_types = define_types(args, scope)

        return receiver if receiver.dynamic?

        if receiver.unresolved_constraint?
          return receiver
              .define_required_method(receiver, name, arg_types, typedb)
              .returns
        end

        symbol = receiver.lookup_method(name)
        method_type = symbol.type

        unless method_type.block?
          diagnostics.undefined_method_error(receiver, name, location)

          return method_type
        end

        verify_send_arguments(receiver, method_type, args, location)

        rtype = method_type
          .initialized_return_type(receiver, arg_types)

        [rtype, method_type]
      end

      def verify_send_arguments(receiver_type, type, arguments, location)
        given_count = arguments.length

        return unless verify_keyword_arguments(type, arguments)

        if type.valid_number_of_arguments?(given_count)
          verify_send_argument_types(receiver_type, type, arguments)
        else
          diagnostics.argument_count_error(
            given_count,
            type.argument_count_range,
            location
          )
        end
      end

      def verify_keyword_arguments(type, arguments)
        arguments.all? do |arg|
          next true unless arg.keyword_argument?
          next true if type.lookup_argument(arg.name).any?

          diagnostics
            .undefined_keyword_argument_error(arg.name, type, arg.location)

          false
        end
      end

      def verify_send_argument_types(receiver_type, type, arguments)
        receiver_is_module = receiver_type == @module.type

        arguments.each_with_index do |arg, index|
          # We add +1 to the index to skip the self argument.
          key = arg.keyword_argument? ? arg.name : index + 1
          exp = type.type_for_argument_or_rest(key)

          if exp.generated_trait?
            if (instance = receiver_type.type_parameter_instances[exp.name])
              exp = instance
            elsif arg.type.type_compatible?(exp) && !receiver_is_module
              receiver_type.init_type_parameter(exp.name, arg.type)
            end
          end

          verify_send_argument(arg, exp, arg.location)
        end
      end

      def verify_send_argument(argument, expected, location)
        given = argument.type

        if expected.generated_trait? && !given.implements_trait?(expected)
          diagnostics
            .generated_trait_not_implemented_error(expected, given, location)

          return
        end

        given.infer_to(expected) if infer_block?(given, expected)

        return if given.type_compatible?(expected)

        diagnostics.type_error(expected, given, location)
      end

      def infer_block?(given, expected)
        given.block? && expected.block? && given.infer?
      end

      def receiver_type(node, scope)
        name = node.name

        node.receiver_type =
          if node.receiver
            define_type(node.receiver, scope)
          elsif scope.self_type.lookup_method(name).any?
            scope.self_type
          elsif @module.globals[name].any?
            @module.type
          else
            scope.self_type
          end
      end

      def on_raw_instruction(node, scope)
        callback = node.raw_instruction_visitor_method

        # Although we don't directly use the argument types here we still want
        # to store them in every node so we can access them later on.
        node.arguments.each { |arg| define_type(arg, scope) }

        if respond_to?(callback)
          public_send(callback, node, scope)
        else
          diagnostics.unknown_raw_instruction_error(node.name, node.location)
          typedb.nil_type
        end
      end

      def on_raw_get_toplevel(*)
        typedb.top_level
      end

      def on_raw_set_prototype(node, *)
        object = node.arguments.fetch(0).type
        proto = node.arguments.fetch(1).type

        object.prototype = proto

        proto
      end

      def on_raw_set_attribute(node, *)
        object = node.arguments.fetch(0).type
        name = node.arguments.fetch(1)
        value = node.arguments.fetch(2).type

        object.define_attribute(name.value, value) if name.string?

        value
      end

      def on_raw_set_object(node, *)
        proto =
          if (proto_node = node.arguments[1])
            proto_node.type
          end

        Type::Object.new(prototype: proto)
      end

      def on_raw_integer_to_string(*)
        typedb.string_type
      end

      def on_raw_stdout_write(*)
        typedb.integer_type
      end

      def on_raw_get_true(*)
        typedb.true_type
      end

      def on_raw_get_false(*)
        typedb.false_type
      end

      def on_raw_get_nil(*)
        typedb.nil_type
      end

      def on_raw_run_block(node, *)
        node.arguments[0].type.return_type
      end

      def on_raw_get_string_prototype(*)
        typedb.string_type
      end

      def on_raw_get_integer_prototype(*)
        typedb.integer_type
      end

      def on_raw_get_float_prototype(*)
        typedb.float_type
      end

      def on_raw_get_array_prototype(*)
        typedb.array_type
      end

      def on_raw_get_block_prototype(*)
        typedb.block_type
      end

      def on_return(node, scope)
        if node.value
          define_type(node.value, scope)
        else
          typedb.nil_type
        end
      end

      def on_throw(node, scope)
        throw_type = define_type(node.value, scope)

        # For block types we infer the throw type so one doesn't have to
        # annotate every block with an explicit type.
        scope.block_type.throws ||= throw_type if scope.closure?

        typedb.void_type
      end

      def on_try(node, scope)
        node.try_block_type =
          block_type_with_self(Config::TRY_BLOCK_NAME, scope.self_type)

        node.else_block_type =
          block_type_with_self(Config::ELSE_BLOCK_NAME, scope.self_type)

        try_scope =
          TypeScope.new(scope.self_type, node.try_block_type, scope.locals)

        try_type =
          node.try_block_type.returns =
            define_type(node.expression, try_scope)

        else_scope = node.type_scope_for_else(scope.self_type)

        node.define_else_argument_type

        else_type = else_type_for_try(node, else_scope)

        if try_type.physical_type? &&
           else_type.physical_type? &&
           !else_type.type_compatible?(try_type)
          diagnostics.type_error(try_type, else_type, node.else_body.location)
        end

        try_type.if_physical_or_else { else_type }
      end

      def else_type_for_try(node, scope)
        if node.else_body.empty?
          node.else_body.type = Type::Void.new
        else
          define_type(node.else_body, scope)
        end
      end

      def block_type_with_self(name, self_type)
        type = Type::Block.new(name: name, prototype: typedb.block_type)

        type.define_self_argument(self_type)
        type
      end

      def on_object(node, scope)
        name = node.name
        proto = typedb.object_type
        type = Type::Object.new(name: name, prototype: proto)

        type.define_attribute(
          Config::OBJECT_NAME_INSTANCE_ATTRIBUTE,
          typedb.string_type
        )

        block_type = define_block_type_for_object(node, type)
        new_scope = TypeScope.new(type, block_type, node.body.locals)

        define_type_parameters(node.type_parameters, type)
        store_type(type, scope.self_type, node.location)
        define_type(node.body, new_scope)

        type
      end

      def define_block_type_for_object(node, type)
        node.block_type = Type::Block.new(
          prototype: typedb.block_type,
          returns: node.body.type
        )

        node.block_type.define_self_argument(type)
        node.block_type
      end

      def on_trait(node, scope)
        name = node.name
        type = Type::Trait.new(name: name, prototype: typedb.trait_type)

        define_type_parameters(node.type_parameters, type)

        node.required_traits.each do |trait|
          trait_type = resolve_module_type(trait, scope.self_type)
          type.required_traits << trait_type if trait_type.trait?
        end

        block_type = define_block_type_for_object(node, type)
        new_scope = TypeScope.new(type, block_type, node.body.locals)

        store_type(type, scope.self_type, node.location)
        define_type(node.body, new_scope)

        type
      end

      def on_trait_implementation(node, scope)
        self_type = scope.self_type
        loc = node.location

        trait = resolve_module_type(node.trait_name, self_type)
        object = resolve_module_type(node.object_name, self_type)

        block_type = define_block_type_for_object(node, object)
        new_scope = TypeScope.new(object, block_type, node.body.locals)

        # We add the trait to the object first so type checks comparing the
        # object and trait will pass.
        object.implemented_traits << trait

        define_type(node.body, new_scope)

        traits_implemented = required_traits_implemented?(object, trait, loc)
        methods_implemented = required_methods_implemented?(object, trait, loc)

        unless traits_implemented && methods_implemented
          object.implemented_traits.delete(trait)
        end

        object
      end

      def on_reopen_object(node, scope)
        self_type = scope.self_type
        object = resolve_module_type(node.name, self_type)
        block_type = define_block_type_for_object(node, object)
        new_scope = TypeScope.new(object, block_type, node.body.locals)

        define_type(node.body, new_scope)
      end

      def required_traits_implemented?(object, trait, location)
        trait.required_traits.each do |req_trait|
          next if object.implements_trait?(req_trait)

          diagnostics
            .uninplemented_trait_error(trait, object, req_trait, location)

          return false
        end

        true
      end

      def required_methods_implemented?(object, trait, location)
        trait.required_methods.each do |method|
          next if object.implements_method?(method)

          diagnostics.unimplemented_method_error(method.type, object, location)

          return false
        end
      end

      def on_method(node, scope)
        self_type = scope.self_type

        type = Type::Block.new(
          name: node.name,
          prototype: typedb.block_type,
          block_type: :method
        )

        new_scope = TypeScope.new(self_type, type, node.body.locals)

        block_signature(node, type, new_scope)

        if node.required?
          if self_type.trait?
            self_type.define_required_method(type)
          else
            diagnostics.define_required_method_on_non_trait_error(node.location)
          end
        else
          store_type(type, self_type, node.location)

          @method_bodies << DeferredMethod.new(node, new_scope)
        end

        type
      end

      def process_deferred_method(method)
        node = method.ast
        body = node.body

        define_type(body, method.scope)

        expected_type = node.type
          .return_type
          .resolve_type(method.scope.self_type)

        inferred_type = body.type

        return if inferred_type.type_compatible?(expected_type)

        diagnostics
          .return_type_error(expected_type, inferred_type, node.location)
      end

      def on_block(node, scope)
        type = Type::Block.new(prototype: typedb.block_type)
        new_scope = TypeScope.new(scope.self_type, type, node.body.locals)

        block_signature(node, type, new_scope, constraints: true)
        define_type(node.body, new_scope)

        rtype = node.body.type
        exp = type.return_type.resolve_type(scope.self_type)

        type.returns = rtype if type.returns.dynamic?

        unless rtype.type_compatible?(exp)
          diagnostics.return_type_error(exp, rtype, node.location)
        end

        type
      end

      def on_define_variable(node, scope)
        callback = node.variable.define_variable_visitor_method
        vtype = define_type(node.value, scope)

        if node.value_type
          exp_type = resolve_module_type(node.value_type, scope.self_type)

          # If an explicit type is given and the inferred type is compatible we
          # want to use the _explicit type_ as _the_ type, instead of the
          # inferred one.
          if vtype.type_compatible?(exp_type)
            vtype = exp_type
          else
            diagnostics.type_error(exp_type, vtype, node.location)
          end
        end

        public_send(callback, node, vtype, scope)

        node.variable.type = vtype
      end

      def on_define_constant(node, value_type, scope)
        name = node.variable.name
        store_type(value_type, scope.self_type, node.location, name)
      end

      def on_define_attribute(node, value_type, scope)
        var = node.variable

        if scope.method? && scope.block_type.name == Config::INIT_MESSAGE
          scope.self_type.define_attribute(node.variable.name, value_type)
        else
          diagnostics.define_instance_attribute_error(var.name, var.location)
        end
      end

      def on_define_local(node, value_type, scope)
        scope.locals.define(node.variable.name, value_type, node.mutable?)
      end

      def on_reassign_variable(node, scope)
        callback = node.variable.reassign_variable_visitor_method
        vtype = define_type(node.value, scope)

        public_send(callback, node, vtype, scope)

        node.variable.type = vtype
      end

      def on_reassign_attribute(node, value_type, scope)
        name = node.variable.name
        symbol = scope.self_type.lookup_attribute(name)
        existing_type = symbol.type

        if symbol.nil?
          diagnostics.reassign_undefined_attribute_error(name, node.location)
          return existing_type
        end

        unless symbol.mutable?
          diagnostics.reassign_immutable_attribute_error(name, node.location)
          return existing_type
        end

        return if value_type.type_compatible?(existing_type)

        diagnostics.type_error(existing_type, value_type, node.value.location)
      end

      def on_reassign_local(node, value_type, scope)
        name = node.variable.name
        _, local = scope.locals.lookup_with_parent(name)
        existing_type = local.type

        if local.nil?
          diagnostics.reassign_undefined_local_error(name, node.location)
          return existing_type
        end

        unless local.mutable?
          diagnostics.reassign_immutable_local_error(name, node.location)
          return existing_type
        end

        return if value_type.type_compatible?(existing_type)

        diagnostics.type_error(existing_type, value_type, node.value.location)
      end

      def block_signature(node, type, scope, constraints: false)
        define_type_parameters(node.type_parameters, type)
        define_arguments(node.arguments, type, scope, constraints: constraints)
        define_return_type(node, type, scope.self_type)
        define_throw_type(node, type, scope.self_type)
      end

      def define_arguments(arguments, block_type, scope, constraints: false)
        block_type.define_self_argument(scope.self_type)

        arguments.each do |arg|
          val_type = type_for_argument_value(arg, scope)
          def_type = defined_type_for_argument(arg, block_type, scope.self_type)

          # If both an explicit type and default value are given we need to make
          # sure the two are compatible.
          if argument_types_incompatible?(def_type, val_type)
            diagnostics.type_error(def_type, val_type, arg.default.location)
          end

          arg_name = arg.name
          mutable = arg.mutable?
          arg_type =
            def_type ||
            val_type ||
            default_argument_type(constraints: constraints)

          arg_symbol =
            if arg.default
              block_type.define_argument(arg_name, arg_type, mutable)
            elsif arg.rest?
              block_type.define_rest_argument(arg_name, arg_type, mutable)
            else
              block_type.define_required_argument(arg_name, arg_type, mutable)
            end

          arg.type = arg_type

          scope.locals.add_symbol(arg_symbol)
        end
      end

      def default_argument_type(constraints: false)
        if constraints
          Type::Constraint.new
        else
          Type::Dynamic.new
        end
      end

      def define_return_type(node, block_type, self_type)
        rnode = node.returns

        unless rnode
          block_type.returns = Type::Dynamic.new
          return
        end

        if rnode.self_type?
          block_type.returns = Type::SelfType.new
          return
        end

        block_type.returns = wrap_optional_type(
          rnode,
          resolve_type(rnode, self_type, [block_type, self_type, @module])
        )
      end

      def define_throw_type(node, block_type, self_type)
        return unless node.throws

        block_type.throws = wrap_optional_type(
          node.throws,
          resolve_type(node.throws, self_type, [block_type, self_type, @module])
        )
      end

      def type_for_argument_value(arg, scope)
        define_type(arg.default, scope) if arg.default
      end

      def defined_type_for_argument(arg, block_type, self_type)
        return unless arg.type

        wrap_optional_type(
          arg.type,
          resolve_type(arg.type, self_type, [block_type, self_type, @module])
        )
      end

      def argument_types_incompatible?(defined_type, value_type)
        defined_type && value_type && !defined_type.type_compatible?(value_type)
      end

      def store_type(type, self_type, location, name = type.name)
        self_type.define_attribute(name, type)

        if Config::RESERVED_CONSTANTS.include?(name)
          diagnostics.redefine_reserved_constant_error(name, location)
        end

        return if type.block? || !module_scope?(self_type)

        @module.globals.define(name, type)
      end

      def module_scope?(self_type)
        self_type == @module.type
      end

      def wrap_optional_type(node, type)
        node.optional? ? Type::Optional.new(type) : type
      end

      def define_type_parameters(arguments, type)
        proto = typedb.trait_type

        arguments.each do |arg_node|
          required_traits = arg_node.required_traits.map do |node|
            resolve_type(node, type, [type, self.module])
          end

          trait = Type::Trait
            .new(name: arg_node.name, prototype: proto, generated: true)

          trait.required_traits.merge(required_traits)
          type.define_type_parameter(trait.name, trait)
        end
      end

      def resolve_module_type(node, self_type)
        resolve_type(node, self_type, [self_type, @module])
      end

      def resolve_type(node, self_type, sources)
        return Type::SelfType.new if node.self_type?
        return Type::Dynamic.new if node.dynamic_type?
        return resolve_block_type(node, self_type, sources) if node.block_type?

        name = node.name

        if node.receiver
          receiver = resolve_type(node.receiver, self_type, sources)
          sources = [receiver] + sources
        end

        sources.find do |source|
          if (type = source.lookup_type(name))
            return type
          end
        end

        diagnostics.undefined_constant_error(node.name, node.location)

        Type::Dynamic.new
      end

      def resolve_block_type(node, self_type, sources)
        args = node.arguments.map do |arg|
          resolve_type(arg, self_type, sources)
        end

        returns =
          if (rnode = node.returns)
            resolve_type(rnode, self_type, sources)
          end

        throws =
          if (tnode = node.throws)
            resolve_type(tnode, self_type, sources)
          end

        type = Type::Block.new(
          prototype: typedb.block_type,
          returns: returns,
          throws: throws
        )

        type.define_self_argument(self_type)

        args.each_with_index do |arg, index|
          type.define_argument(index.to_s, arg)
        end

        wrap_optional_type(node, type)
      end

      def inspect
        # The default inspect is very slow, slowing down the rendering of any
        # runtime errors.
        '#<Pass::DefineTypes>'
      end
    end
  end
end
