defmodule Wymcp.Tool.SchemaTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for the Tool schema builder.

  The schema builder converts a map of action definitions into a JSON Schema
  with `oneOf` variants discriminated by the `action` field. Each variant
  uses `const` on the action property so that MCP clients and LLMs can see
  the full input contract per action in `tools/list`.

  Key design decisions tested here:
  - Actions with required data fields mark `data` as required in their variant
  - Actions without required fields leave `data` optional
  - Action descriptions appear as variant-level `description` fields
  - The top-level `enum` on `action` lists all available actions
  - Properties from each action schema appear under `data.properties`
  """

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
    }
  }

  describe "build/1" do
    test "returns object schema with required action field" do
      schema = Schema.build(@actions)

      assert schema["type"] == "object"
      assert schema["required"] == ["action"]
    end

    test "action property lists all action names as enum" do
      schema = Schema.build(@actions)
      enum = schema["properties"]["action"]["enum"]

      assert Enum.sort(enum) == ["create", "get", "list"]
    end

    test "generates one oneOf variant per action" do
      schema = Schema.build(@actions)

      assert length(schema["oneOf"]) == 3
    end

    @tag doc: "Actions with required fields force data to be required too"
    test "variant with required fields includes data in required" do
      schema = Schema.build(@actions)
      create = find_variant(schema, "create")

      assert "data" in create["required"]
      assert "action" in create["required"]
      assert create["properties"]["data"]["required"] == ["name"]
    end

    @tag doc: "Actions without required fields leave data optional"
    test "variant without required fields omits data from required" do
      schema = Schema.build(@actions)
      list = find_variant(schema, "list")

      assert list["required"] == ["action"]
      refute Map.has_key?(list["properties"]["data"], "required")
    end

    test "variant includes action description" do
      schema = Schema.build(@actions)
      get = find_variant(schema, "get")

      assert get["description"] == "Get a widget by ID"
    end

    test "variant includes property definitions in data schema" do
      schema = Schema.build(@actions)
      create = find_variant(schema, "create")

      assert create["properties"]["data"]["properties"]["name"]["type"] == "string"
      assert create["properties"]["data"]["properties"]["name"]["minLength"] == 1
      assert create["properties"]["data"]["properties"]["color"]["type"] == "string"
    end

    test "each variant uses const for action discriminator" do
      schema = Schema.build(@actions)
      get = find_variant(schema, "get")

      assert get["properties"]["action"]["const"] == "get"
    end

    @tag doc: "Empty actions map produces valid but empty schema"
    test "handles empty actions map" do
      schema = Schema.build(%{})

      assert schema["type"] == "object"
      assert schema["oneOf"] == []
      assert schema["properties"]["action"]["enum"] == []
    end
  end

  describe "build_slim/1" do
    test "returns object schema with required action field" do
      schema = Schema.build_slim(@actions)

      assert schema["type"] == "object"
      assert schema["required"] == ["action"]
    end

    test "action enum includes help, describe, and all declared actions" do
      schema = Schema.build_slim(@actions)
      enum = schema["properties"]["action"]["enum"]

      assert "help" in enum
      assert "describe" in enum
      assert "create" in enum
      assert "get" in enum
      assert "list" in enum
    end

    test "action description contains one-liner for each declared action" do
      schema = Schema.build_slim(@actions)
      desc = schema["properties"]["action"]["description"]

      assert desc =~ "create"
      assert desc =~ "Create a widget"
      assert desc =~ "get"
      assert desc =~ "Get a widget by ID"
      assert desc =~ "help"
      assert desc =~ "describe"
    end

    test "data property is a bare object with no description" do
      schema = Schema.build_slim(@actions)
      data = schema["properties"]["data"]

      assert data == %{"type" => "object"}
    end

    test "does not include oneOf variants" do
      schema = Schema.build_slim(@actions)

      refute Map.has_key?(schema, "oneOf")
    end

    @tag doc: """
         Verifies the primary motivation for slim mode. If this fails, slim mode
         no longer provides meaningful size reduction and its trade-off is broken.
         """
    test "slim schema is substantially smaller than full schema" do
      full_size = Schema.build(@actions) |> JSON.encode!() |> byte_size()
      slim_size = Schema.build_slim(@actions) |> JSON.encode!() |> byte_size()

      assert slim_size < full_size / 2
    end

    @tag doc: "Empty actions map still produces a valid schema with help and describe in the enum"
    test "handles empty actions map" do
      schema = Schema.build_slim(%{})

      assert schema["type"] == "object"
      assert "help" in schema["properties"]["action"]["enum"]
      assert "describe" in schema["properties"]["action"]["enum"]
    end
  end

  defp find_variant(schema, action_name) do
    Enum.find(schema["oneOf"], fn v ->
      v["properties"]["action"]["const"] == action_name
    end)
  end
end
