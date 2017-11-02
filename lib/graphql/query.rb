# frozen_string_literal: true
require "graphql/query/arguments"
require "graphql/query/arguments_cache"
require "graphql/query/context"
require "graphql/query/executor"
require "graphql/query/literal_input"
require "graphql/query/null_context"
require "graphql/query/preparation_pipeline"
require "graphql/query/result"
require "graphql/query/serial_execution"
require "graphql/query/variables"
require "graphql/query/input_validation_result"
require "graphql/query/variable_validation_error"

module GraphQL
  # A combination of query string and {Schema} instance which can be reduced to a {#result}.
  class Query
    include Tracing::Traceable
    extend GraphQL::Delegate

    class OperationNameMissingError < GraphQL::ExecutionError
      def initialize(name)
        msg = if name.nil?
          %|An operation name is required|
        else
          %|No operation named "#{name}"|
        end
        super(msg)
      end
    end

    attr_reader :schema, :context, :root_value, :warden, :provided_variables

    # @return [nil, String] The operation name provided by client or the one inferred from the document. Used to determine which operation to run.
    attr_accessor :operation_name

    # @return [Boolean] if false, static validation is skipped (execution behavior for invalid queries is undefined)
    attr_accessor :validate

    attr_accessor :query_string

    # @return [GraphQL::Language::Nodes::Document]
    def document
      prepare
      @document
    end

    # @return [String, nil] The name of the operation to run (may be inferred)
    def selected_operation_name
      prepare
      selected_operation && selected_operation.name
    end

    # @return [String, nil] the triggered event, if this query is a subscription update
    attr_reader :subscription_topic

    # @return [String, nil]
    attr_reader :operation_name

    attr_reader :tracers

    # Prepare query `query_string` on `schema`
    # @param schema [GraphQL::Schema]
    # @param query_string [String]
    # @param context [#[]] an arbitrary hash of values which you can access in {GraphQL::Field#resolve}
    # @param variables [Hash] values for `$variables` in the query
    # @param operation_name [String] if the query string contains many operations, this is the one which should be executed
    # @param root_value [Object] the object used to resolve fields on the root type
    # @param max_depth [Numeric] the maximum number of nested selections allowed for this query (falls back to schema-level value)
    # @param max_complexity [Numeric] the maximum field complexity for this query (falls back to schema-level value)
    # @param except [<#call(schema_member, context)>] If provided, objects will be hidden from the schema when `.call(schema_member, context)` returns truthy
    # @param only [<#call(schema_member, context)>] If provided, objects will be hidden from the schema when `.call(schema_member, context)` returns false
    def initialize(schema, query_string = nil, query: nil, document: nil, context: nil, variables: {}, validate: true, subscription_topic: nil, operation_name: nil, root_value: nil, max_depth: nil, max_complexity: nil, except: nil, only: nil)
      @schema = schema
      @filter = schema.default_filter.merge(except: except, only: only)
      @context = Context.new(query: self, object: root_value, values: context)
      @subscription_topic = subscription_topic
      @root_value = root_value
      @fragments = nil
      @operations = nil
      @validate = validate
      # TODO: remove support for global tracers
      @tracers = schema.tracers + GraphQL::Tracing.tracers + (context ? context.fetch(:tracers, []) : [])
      # Support `ctx[:backtrace] = true` for wrapping backtraces
      if context && context[:backtrace] && !@tracers.include?(GraphQL::Backtrace::Tracer)
        @tracers << GraphQL::Backtrace::Tracer
      end

      @analysis_errors = []
      @validation_errors = []
      @analyzers = []

      if variables.is_a?(String)
        raise ArgumentError, "Query variables should be a Hash, not a String. Try JSON.parse to prepare variables."
      else
        @provided_variables = variables
      end

      @query_string = query_string || query
      @document = document

      if @query_string && @document
        raise ArgumentError, "Query should only be provided a query string or a document, not both."
      end

      # A two-layer cache of type resolution:
      # { abstract_type => { value => resolved_type } }
      @resolved_types_cache = Hash.new do |h1, k1|
        h1[k1] = Hash.new do |h2, k2|
          h2[k2] = @schema.resolve_type(k1, k2, @context)
        end
      end

      @arguments_cache = ArgumentsCache.build(self)

      # Trying to execute a document
      # with no operations returns an empty hash
      @mutation = false
      @query = false
      @subscription = false
      @operation_name = operation_name
      @max_depth = max_depth || schema.max_depth
      @max_complexity = max_complexity || schema.max_complexity
      @result_values = nil
      @executed = false
      @prepared = false
      @warden = GraphQL::Schema::Warden.new(@filter, schema: @schema, context: @context)
    end

    def subscription_update?
      @subscription_topic && subscription?
    end

    # @api private
    def result_values=(result_hash)
      if @executed
        raise "Invariant: Can't reassign result"
      else
        @executed = true
        @result_values = result_hash
      end
    end

    def fragments
      prepare
      @fragments
    end

    def operations
      prepare
      @operations
    end

    # Get the result for this query, executing it once
    # @return [Hash] A GraphQL response, with `"data"` and/or `"errors"` keys
    def result
      if !@executed
        prepare
        Execution::Multiplex.run_queries(@schema, [self])
      end
      @result ||= Query::Result.new(query: self, values: @result_values)
    end

    def static_errors
      validation_errors + analysis_errors + context.errors
    end

    # This is the operation to run for this query.
    # If more than one operation is present, it must be named at runtime.
    # @return [GraphQL::Language::Nodes::OperationDefinition, nil]
    def selected_operation
      prepare
      @selected_operation
    end

    # Determine the values for variables of this query, using default values
    # if a value isn't provided at runtime.
    #
    # If some variable is invalid, errors are added to {#validation_errors}.
    #
    # @return [GraphQL::Query::Variables] Variables to apply to this query
    def variables
      prepare
      @variables
    end

    def irep_selection
      @selection ||= begin
        if selected_operation
          internal_representation.operation_definitions[selected_operation.name]
        else
          nil
        end
      end
    end

    # Node-level cache for calculating arguments. Used during execution and query analysis.
    # @api private
    # @return [GraphQL::Query::Arguments] Arguments for this node, merging default values, literal values and query variables
    def arguments_for(irep_or_ast_node, definition)
      @arguments_cache[irep_or_ast_node][definition]
    end

    attr_reader :analyzers, :validation_errors, :max_depth, :max_complexity
    attr_accessor :analysis_errors

    def internal_representation
      prepare
      @internal_representation
    end

    def valid?
      prepare
      validation_errors.none? && analysis_errors.none? && @context.errors.none?
    end

    attr_reader :warden

    def_delegators :warden, :get_type, :get_field, :possible_types, :root_type_for_operation

    # @param abstract_type [GraphQL::UnionType, GraphQL::InterfaceType]
    # @param value [Object] Any runtime value
    # @return [GraphQL::ObjectType, nil] The runtime type of `value` from {Schema#resolve_type}
    # @see {#possible_types} to apply filtering from `only` / `except`
    def resolve_type(abstract_type, value = :__undefined__)
      if value.is_a?(Symbol) && value == :__undefined__
        # Old method signature
        value = abstract_type
        abstract_type = nil
      end
      @resolved_types_cache[abstract_type][value]
    end

    def mutation?
      prepare
      @mutation
    end

    def query?
      prepare
      @query
    end

    # @return [void]
    def merge_filters(only: nil, except: nil)
      if @prepared
        raise "Can't add filters after preparing the query"
      else
        @filter = @filter.merge(only: only, except: except)
      end
      nil
    end

    def subscription?
      prepare
      @subscription
    end

    # Parse the AST, validate, prepare IRep
    # @return [void]
    # @api private
    def prepare
      if !@prepared
        @prepared = true
        PreparationPipeline.call(self)
      end
    end
  end
end
