defmodule Wymcp.Tool.SchemaTest do
  use ExUnit.Case, async: true

  alias Wymcp.Tool.Schema

  @actions %{
    create: %{
      description: "Create a widget",
      properties: %{
        "name" => %{"type" => "string", "minLength" => 1},
        "color" => %{"type" => "string"}
      },
      required: ["name"],
      defaults: %{"color" => "blue"}
    },
    get: %{
      description: "Get a widget by ID",
      properties: %{
        "id" => %{"type" => "integer", "minimum" => 1}
      },
      required: ["id"],
      defaults: %{}
    },
    list: %{
      description: "List all widgets",
      properties: %{
        "limit" => %{"type" => "integer", "default" => 10}
      },
      required: [],
      defaults: %{"limit" => 10}
    },
    identify: %{
      description: "Identify by id or by (name + color)",
      properties: %{
        "id" => %{"type" => "integer"},
        "name" => %{"type" => "string"},
        "color" => %{"type" => "string"}
      },
      required_one_of: [["id"], ["name", "color"]],
      defaults: %{}
    }
  }

  describe "build/1" do
    test "returns object schema with required action field" do
      schema = Schema.build(@actions)

      assert schema["type"] == "object"
      assert schema["required"] == ["action"]
    end

    test "action enum lists exactly the declared action names" do
      schema = Schema.build(@actions)

      assert schema["properties"]["action"]["enum"] == ["create", "get", "identify", "list"]
    end

    test "action description carries one one-liner per action and nothing else" do
      schema = Schema.build(@actions)
      description = schema["properties"]["action"]["description"]

      assert description ==
               Enum.join(Schema.action_summaries(@actions), ". ")

      refute description =~ "help:"
      refute description =~ "describe:"
    end

    test "data property is a bare object" do
      schema = Schema.build(@actions)

      assert schema["properties"]["data"] == %{"type" => "object"}
    end

    test "does not include oneOf variants" do
      refute Map.has_key?(Schema.build(@actions), "oneOf")
    end

    test "handles empty actions map" do
      schema = Schema.build(%{})

      assert schema["properties"]["action"]["enum"] == []
      assert schema["properties"]["action"]["description"] == ""
    end
  end

  describe "action_summaries/1" do
    test "returns one one-liner per action, sorted by action name" do
      assert Schema.action_summaries(@actions) == [
               "create: Create a widget",
               "get: Get a widget by ID",
               "identify: Identify by id or by (name + color)",
               "list: List all widgets"
             ]
    end

    test "returns an empty list for an empty actions map" do
      assert Schema.action_summaries(%{}) == []
    end
  end
end
