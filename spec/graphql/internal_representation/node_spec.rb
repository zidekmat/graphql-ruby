# frozen_string_literal: true
require "spec_helper"

describe GraphQL::InternalRepresentation::Node do
  class ArgumentAccessAnalyzer
    def initial_value(query)
      query.context[:args]
    end
    def call(m,visit_type,irep_node)
      if visit_type == :enter
        m << irep_node.arguments # make sure this works
      end
      m
    end
  end

  let(:analyzer_schema) {
    Dummy::Schema.redefine {
      query_analyzer(ArgumentAccessAnalyzer.new)
    }
  }

  let(:query_string) { '{ __type(name: "missingtype") { name } }'}

  describe "#arguments" do
    it "returns the Arguments instance or nil" do
      args = []
      res = analyzer_schema.execute(query_string, context: { args: args })
      assert_equal({ "data" => {"__type" => nil }}, res)
      assert_equal(3, args.length)
      assert_equal GraphQL::Query::Arguments::NO_ARGS, args[0]
      assert_kind_of GraphQL::Query::Arguments, args[1]
      assert_equal "missingtype", args[1]["name"]
      assert_equal GraphQL::Query::Arguments::NO_ARGS, args[2]
    end
  end
end
