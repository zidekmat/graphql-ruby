# frozen_string_literal: true
# test_via: ./object.rb
module GraphQL
  module TypeSystem
    module ClassMethods
      # Users can override these classes, but we provide some defaults, too.
      def const_missing(const_name)
        puts "Looking up #{const_name}"
        if GraphQL::Object.const_defined?(const_name)
          GraphQL::Object.const_get(const_name)
        elsif GraphQL.const_defined?(const_name)
          GraphQL.const_get(const_name)
        else
          super
        end
      end
    end

    def self.included(child)
      puts "Including #{child}"
      child.extend(ClassMethods)
    end
  end
end
