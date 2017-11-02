# frozen_string_literal: true
# test_via: ../query.rb
module GraphQL
  class Query
    # Given an initalized {GraphQL::Query}, prepare it for execution.
    #
    # 1. Prepare the AST
    #   1a. If there's a query string, parse it
    #   1b. Ensure that a parsed document is present
    #   1c. Ensure that a selected operation is present
    #   1d. Validate the AST, if required
    # 2. Prepare runtime data
    #   2a. Ensure provided_variables are sufficient
    #   2b. Prepare all arguments
    #   2c. Prepare query analyzers
    #
    # Any of the checks above may cause the pipeline to halt.
    #
    # Results of this preparation procedure are written back to the query.
    #
    # You can't quite run the analyzers yet; They get run later, perhaps
    # as part of a multiplex.
    #
    # @api private
    class PreparationPipeline
      # TODO find a way to write back to `query`
      def self.call(query)
        schema = query.schema
        context = query.context
        document = query.document
        parse_error = nil
        # Parse the query string, if there is one
        if query.query_string
          begin
            document = GraphQL.parse(query.query_string, tracer: query)
          rescue GraphQL::ParseError => parse_error
            schema.parse_error(parse_error, context)
          end
        end

        # Assert that one of the document's operations can be run
        # Or, if there are no operations, we return an empty string from {Query#result}
        fragments = {}
        operations = {}
        validation_errors = []
        if parse_error
          # Nothing to do here
        elsif !document
          # Assert that a document is present
          validation_errors << GraphQL::ExecutionError.new("No query string was present")
        else
          document.definitions.each do |part|
            case part
            when GraphQL::Language::Nodes::FragmentDefinition
              fragments[part.name] = part
            when GraphQL::Language::Nodes::OperationDefinition
              operations[part.name] = part
            end
          end

          query.instance_variable_set(:@document, document)
          query.instance_variable_set(:@fragments, fragments)
          query.instance_variable_set(:@operations, operations)
        end

        if operations.any?
          operation_name = query.operation_name
          selected_operation = if operation_name.nil? && operations.length == 1
            operations.values.first
          else
            operations[operation_name]
          end

          if selected_operation.nil?
            context.add_error(GraphQL::Query::OperationNameMissingError.new(operation_name))
            ast_variables = []
          else
            operation_name ||= selected_operation.name
            ast_variables = selected_operation.variables

            query.instance_variable_set(:@mutation, selected_operation.operation_type == "mutation")
            query.instance_variable_set(:@query, selected_operation.operation_type == "query")
            query.instance_variable_set(:@subscription, selected_operation.operation_type == "subscription")
            query.instance_variable_set(:@selected_operation, selected_operation)
            query.instance_variable_set(:@operation_name, operation_name)
          end
        else
          ast_variables = []
        end

        variables = GraphQL::Query::Variables.new(context, ast_variables, query.provided_variables)
        query.instance_variable_set(:@variables, variables)

        if document && !parse_error
          validation_result = schema.static_validator.validate(query, validate: query.validate)
          validation_errors.concat(validation_result[:errors])
          internal_representation = validation_result[:irep]

          if validation_errors.none?
            validation_errors.concat(variables.errors)
          end

          if validation_errors.none?
            max_depth = query.max_depth
            max_complexity = query.max_complexity
            # If there are max_* values, add them,
            # otherwise reuse the schema's list of analyzers.
            query_analyzers = if max_depth || max_complexity
              qa = schema.query_analyzers.dup
              if max_depth
                qa << GraphQL::Analysis::MaxQueryDepth.new(max_depth)
              end
              if max_complexity
                qa << GraphQL::Analysis::MaxQueryComplexity.new(max_complexity)
              end
              qa
            else
              schema.query_analyzers
            end
          end

          query.instance_variable_set(:@internal_representation, internal_representation)
          query.instance_variable_set(:@analyzers, query_analyzers)
        end

        # What a mess. `schema.parse_error` adds entries to this, so we should make sure to preserve it
        query.validation_errors.concat(validation_errors)
      end
    end
  end
end
