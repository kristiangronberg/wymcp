defmodule Wymcp.HintTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Tests for Wymcp.Hint struct.

  The Hint struct enforces a consistent shape for follow-up action suggestions
  in MCP tool responses. It validates required fields at construction time
  and serializes to a flat JSON map.
  """

  alias Wymcp.Hint

  describe "new/1" do
    test "creates hint with all fields" do
      hint =
        Hint.new(
          tool: "tasks",
          action: "get",
          description: "View task",
          example: %{data: %{id: 1}}
        )

      assert %Hint{} = hint
      assert hint.tool == "tasks"
      assert hint.action == "get"
      assert hint.description == "View task"
      assert hint.example == %{data: %{id: 1}}
    end

    test "creates hint without example" do
      hint = Hint.new(tool: "tasks", action: "list", description: "List tasks")

      assert %Hint{} = hint
      assert hint.example == nil
    end

    test "raises on missing required fields" do
      assert_raise ArgumentError, fn ->
        Hint.new(tool: "tasks", action: "get")
      end
    end

    @tag doc: "tool and action must be strings, not atoms — matches JSON wire format"
    test "raises on atom tool or action" do
      assert_raise ArgumentError, fn ->
        Hint.new(tool: :tasks, action: "get", description: "View")
      end

      assert_raise ArgumentError, fn ->
        Hint.new(tool: "tasks", action: :get, description: "View")
      end
    end
  end

  describe "JSON encoding" do
    test "encodes to flat map matching current wire format" do
      hint =
        Hint.new(tool: "tasks", action: "get", description: "View", example: %{data: %{id: 1}})

      json = JSON.encode!(hint)
      decoded = JSON.decode!(json)

      assert decoded == %{
               "tool" => "tasks",
               "action" => "get",
               "description" => "View",
               "example" => %{"data" => %{"id" => 1}}
             }
    end

    test "omits example when nil" do
      hint = Hint.new(tool: "tasks", action: "list", description: "List")
      json = JSON.encode!(hint)
      decoded = JSON.decode!(json)

      refute Map.has_key?(decoded, "example")
    end
  end
end
