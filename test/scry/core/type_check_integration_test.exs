defmodule Scry.Core.TypeCheckIntegrationTest do
  use ExUnit.Case, async: true

  alias Scry.Core

  describe "through real Scry.Core.parse/1 text" do
    test "a TYPE whose name matches its source's own name is enforced" do
      assert {:error, {:type_mismatch, "users", "id", {:named, "Int", nil}, "oops"}} =
               Core.parse(~s[TYPE users { id: Int } SELECT users WHERE id = "oops" { id }])
    end

    test "a TYPE whose name does NOT match any source is inert" do
      assert {:ok, %Scry.Core.Query{}} =
               Core.parse(~s[TYPE Employee { id: Int } SELECT users WHERE id = "oops" { id }])
    end

    test "a degenerate-kind category mismatch is not reachable from scry_core's own grammar" do
      # scry_core's own grammar can never populate `:variant` on its own
      # (`body_item_ep1 := NEVER`, no kind fragment loaded) -- a real
      # end-to-end category-check-failure test through actual query text
      # needs a kind package's own grammar (scry_time_series's suite has
      # the real one). This test locks in that a plain core-only document
      # parses and checks out fine even when tagged with a degenerate kind.
      assert {:ok, %Scry.Core.Query{} = q} =
               Core.parse(~s[TYPE users: relational { id: Int } SELECT users { id }])

      assert q.variant == %{}
    end

    test "a nullable field compared with no guard fails at parse time" do
      assert {:error, {:unguarded_null_comparison, "users", "age"}} =
               Core.parse(~s[TYPE users { age: ?Int } SELECT users WHERE age > 30 { id }])
    end

    test "guarding first, per lang_spec's own worked example, parses cleanly" do
      assert {:ok, %Scry.Core.Query{}} =
               Core.parse(
                 ~s[TYPE users { age: ?Int } SELECT users WHERE NOT age = nil AND age > 30 { id }]
               )
    end

    test "a JSON<{shape}> dot-path outside the declared shape fails at parse time" do
      assert {:error, {:unknown_structured_field, "metadata", "bogus"}} =
               Core.parse(
                 ~s[TYPE users { metadata: JSON<{ color: String }> } SELECT users WHERE metadata.bogus = "x" { id }]
               )
    end

    test "a JSON<{shape}> dot-path inside the declared shape parses cleanly" do
      assert {:ok, %Scry.Core.Query{}} =
               Core.parse(
                 ~s[TYPE users { metadata: JSON<{ color: String }> } SELECT users WHERE metadata.color = "red" { id }]
               )
    end

    test "a WITH-bound query is checked too, matched against its own inline TYPE" do
      assert {:error, {:type_mismatch, "archive", "id", {:named, "Int", nil}, "oops"}} =
               Core.parse(
                 ~s[TYPE archive { id: Int } WITH a = SELECT archive WHERE id = "oops" { id } SELECT a { id }]
               )
    end

    test "a UNION checks both sides independently against their own inline TYPEs" do
      assert {:error, {:type_mismatch, "customers", "id", {:named, "Int", nil}, "oops"}} =
               Core.parse(
                 ~s[TYPE customers { id: Int } SELECT users { id } UNION SELECT customers WHERE id = "oops" { id }]
               )
    end
  end
end
