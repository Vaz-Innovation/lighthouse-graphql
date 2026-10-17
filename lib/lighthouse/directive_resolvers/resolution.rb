# frozen_string_literal: true

module Lighthouse
  module GraphQL
    module DirectiveResolvers
      # Helper for "middleware" directives (@guard, @can) that need to wrap a
      # field's existing resolver.
      module Resolution
        module_function

        # Capture the field's current resolver (generated singleton method,
        # resolve_proc, or the default attribute reader) as a callable
        # (obj, args, ctx) -> value, so it can be wrapped. The returned callable
        # is unaffected by subsequently redefining the singleton method.
        def capture(target_type_class, method_name, field_def, field_name)
          original_singleton = lighthouse_singleton(target_type_class, method_name)
          original_proc = field_def.resolve_proc if field_def.respond_to?(:resolve_proc) && field_def.resolve_proc

          lambda do |obj, arguments, ctx|
            if original_singleton
              original_singleton.call(obj, arguments, ctx)
            elsif original_proc
              original_proc.call(obj, arguments, ctx)
            elsif obj.respond_to?(field_name)
              obj.public_send(field_name)
            else
              snake = Lighthouse::Support::Naming.attribute(field_name)
              obj.respond_to?(snake) ? obj.public_send(snake) : nil
            end
          end
        end

        # graphql-ruby's SDL builder defines `resolve_field_*` methods of its own
        # (with a different arity); only ours, defined under lib/lighthouse/, count.
        def lighthouse_singleton(target_type_class, method_name)
          return nil unless target_type_class.respond_to?(method_name)

          method = target_type_class.method(method_name)
          source_file, = method.source_location
          method if source_file&.include?('/lib/lighthouse/')
        end
      end
    end
  end
end
