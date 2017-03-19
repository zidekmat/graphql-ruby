# frozen_string_literal: true
module GraphQL
  module InternalRepresentation
    class Node
      # @return [String] the name this node has in the response
      attr_reader :name

      # @return [GraphQL::ObjectType]
      attr_reader :owner_type

      # @return [Hash<GraphQL::BaseType, Hash<String => Node>>] selections on this node for each type
      attr_reader :scoped_children

      # @return [Hash<GraphQL::ObjectType, Hash<String => Node>>] selections on this node for each type
      def typed_children
        @typed_children ||= begin
          tc = Hash.new { |h, k| h[k] = {} }
          @scoped_children.each do |scope_type, scope_children|
            each_type(@query, scope_type) do |obj_type|
              deep_merge_children((tc[obj_type] ||= {}), scope_children)
            end
          end
          tc
        end
      end

      # @return [Set<Language::Nodes::AbstractNode>] AST nodes which are represented by this node
      def ast_nodes
        @ast_nodes ||= Set.new
      end

      # @return [Set<GraphQL::Field>] Field definitions for this node (there should only be one!)
      def definitions
        @definitions ||= Set.new
      end

      # @return [GraphQL::BaseType]
      attr_reader :return_type

      def initialize(
          name:, owner_type:, query:, return_type:,
          ast_nodes: nil,
          definitions: nil, scoped_children: nil
        )
        @name = name
        @query = query
        @owner_type = owner_type
        @scoped_children = scoped_children || Hash.new { |h1, k1| h1[k1] = {} }
        @ast_nodes = ast_nodes
        @definitions = definitions
        @return_type = return_type
      end

      def definition_name
        @definition_name ||= definition.name
      end

      def definition
        @definition ||= definitions.first
      end

      def ast_node
        @ast_node ||= ast_nodes.first
      end

      def inspect
        "#<Node #{@owner_type}.#{@name} -> #{@return_type}>"
      end

      private

      # Call the block for each of `owner_type`'s possible types
      def each_type(query, owner_type)
        case owner_type
        when GraphQL::ObjectType, GraphQL::ScalarType, GraphQL::EnumType
          yield(owner_type)
        when GraphQL::UnionType, GraphQL::InterfaceType
          query.possible_types(owner_type).each(&Proc.new)
        when GraphQL::InputObjectType, nil
          # this is an error, don't give 'em nothin
        else
          raise "Unexpected owner type: #{owner_type.inspect} (#{owner_type.class})"
        end
      end

      def deep_merge_children(type_children, scope_children)
        scope_children.each do |name, scope_child|
          type_child = type_children[name]
          if type_child
            type_child.ast_nodes.merge(scope_child.ast_nodes)
            type_child.definitions.merge(scope_child.definitions)
            deep_merge_children(type_child.typed_children, scope_child.scoped_children)
          else
            type_children[name] = scope_child
          end
        end
      end
    end
  end
end
