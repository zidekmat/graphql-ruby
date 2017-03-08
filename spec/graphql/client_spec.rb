require "spec_helper"
require "graphql/client"
require "graphql/client/http"

describe "JSON Schema / Client bug" do
  describe "bug" do
    let(:defn_json) { JSON.parse(File.read("./spec/support/bug_schema.json")) }
    let(:schema) { GraphQL::Schema.from_introspection(defn_json) }

    module RootObj
      module_function

      def locationAll
        [
          OpenStruct.new({
            id: 1,
            name: "Cool Place",
            address: "123 Easy St",
            city: "Anytown",
            state: "CA",
            zip: "92008",
            phoneNumber: "555-1234",
            latitude: 37.5,
            longitude: 100.0,
          })
        ]
      end
    end

    it "executes" do
      query_str = <<-GRAPHQL
        query {
          locationAll {
            ...LocationFragment
          }
        }
        fragment LocationFragment on Location {
          id
          name
          address
          city
          state
          zip
          phoneNumber
          latitude
          longitude
        }
      GRAPHQL

      res = schema.execute(query_str, root_value: RootObj)
      expected_result = {
        "id" => "1",
        "name" => "Cool Place",
        "address" => "123 Easy St",
        "city" => "Anytown",
        "state" => "CA",
        "zip" => "92008",
        "phoneNumber" => "555-1234",
        "latitude" => "37.5",
        "longitude" => "100.0",
      }

      assert_equal expected_result, res["data"]["locationAll"][0]
    end

    it "Works with a client" do
      module CustomNamespace
        HTTP = GraphQL::Client::HTTP.new("https://whatisthisfor/")
        Schema = GraphQL::Client.load_schema("./spec/support/bug_schema.json")
        Client = GraphQL::Client.new(schema: Schema, execute: HTTP)

        LocationFragment = Client.parse <<-'GRAPHQL'
            fragment on Location {
              id
              name
              address
              city
              state
              zip
              phoneNumber
              latitude
              longitude
            }
        GRAPHQL

        LocationAllQuery = Client.parse <<-'GRAPHQL'
            query {
              locationAll {
                ...LocationFragment
              }
            }
        GRAPHQL
      end
    end
  end
end
