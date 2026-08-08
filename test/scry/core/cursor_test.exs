defmodule Scry.Core.CursorTest do
  @moduledoc """
  `Scry.Core.Cursor` -- `next/1` genuinely doesn't force evaluation
  beyond the requested element (a side-effecting generator proves it,
  not just the types lining up), `take/2` terminates against a real
  infinite stream, `skip/1,2` and `to_list/1` compose on top of
  `next/1` correctly, exhaustion (`:done`) behaves the same way
  regardless of what kind of `Enumerable.t()` was wrapped, and
  `close/1` genuinely triggers a `Stream.resource/3`-backed source's
  own cleanup on early termination (proven against a real `after_fun`,
  not just that the call doesn't crash).
  """

  use ExUnit.Case, async: true

  alias Scry.Core.Cursor

  test "next/1 pulls exactly one element at a time, never forcing more than requested" do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    lazy =
      Stream.map(1..5, fn n ->
        Agent.update(agent, &[n | &1])
        n
      end)

    cursor = Cursor.new(lazy)

    assert {:ok, 1, cursor} = Cursor.next(cursor)
    assert Agent.get(agent, & &1) == [1]

    assert {:ok, 2, cursor} = Cursor.next(cursor)
    assert Agent.get(agent, & &1) == [2, 1]

    assert {:ok, 3, _cursor} = Cursor.next(cursor)
    assert Agent.get(agent, & &1) == [3, 2, 1]
  end

  test "next/1 returns :done once exhausted, and stays :done on further calls" do
    cursor = Cursor.new([:a, :b])

    assert {:ok, :a, cursor} = Cursor.next(cursor)
    assert {:ok, :b, cursor} = Cursor.next(cursor)
    assert :done = Cursor.next(cursor)
    assert :done = Cursor.next(cursor)
  end

  test "next/1 on an empty enumerable is immediately :done" do
    assert :done = Cursor.new([]) |> Cursor.next()
  end

  test "take/2 terminates against a genuinely infinite stream, returning exactly n" do
    infinite = Stream.iterate(0, &(&1 + 1))
    cursor = Cursor.new(infinite)

    assert {[0, 1, 2], _rest} = Cursor.take(cursor, 3)
  end

  test "take/2 returns fewer than n, paired with an exhausted cursor, when the source runs out" do
    cursor = Cursor.new([1, 2])

    assert {[1, 2], rest} = Cursor.take(cursor, 5)
    assert :done = Cursor.next(rest)
  end

  test "take/2 with n == 0 returns an empty list and the same cursor, unchanged" do
    cursor = Cursor.new([1, 2, 3])
    assert {[], rest} = Cursor.take(cursor, 0)
    assert {:ok, 1, _} = Cursor.next(rest)
  end

  test "take/2 composed across calls picks up exactly where the previous one left off" do
    cursor = Cursor.new(1..6)
    assert {[1, 2], cursor} = Cursor.take(cursor, 2)
    assert {[3, 4, 5], cursor} = Cursor.take(cursor, 3)
    assert {[6], _cursor} = Cursor.take(cursor, 10)
  end

  test "skip/2 discards exactly n elements" do
    cursor = Cursor.new([1, 2, 3, 4])
    rest = Cursor.skip(cursor, 2)
    assert {:ok, 3, _} = Cursor.next(rest)
  end

  test "skip/1 discards exactly one element" do
    cursor = Cursor.new([1, 2, 3])
    rest = Cursor.skip(cursor)
    assert {:ok, 2, _} = Cursor.next(rest)
  end

  test "skip/2 past the end of the source is a well-defined exhausted cursor, not an error" do
    cursor = Cursor.new([1, 2])
    rest = Cursor.skip(cursor, 10)
    assert :done = Cursor.next(rest)
  end

  test "to_list/1 drains the rest, matching Enum.to_list/1 on the same source" do
    source = [1, 2, 3, 4, 5]
    assert Cursor.new(source) |> Cursor.to_list() == Enum.to_list(source)
  end

  test "to_list/1 after a partial next/1, only the remaining elements" do
    cursor = Cursor.new([1, 2, 3, 4])
    {:ok, 1, cursor} = Cursor.next(cursor)
    assert Cursor.to_list(cursor) == [2, 3, 4]
  end

  test "to_list/1 on an already-exhausted cursor is an empty list" do
    cursor = Cursor.new([])
    :done = Cursor.next(cursor)
    assert Cursor.to_list(cursor) == []
  end

  test "works identically over a plain list, a Range, and a Stream -- any Enumerable.t()" do
    assert Cursor.new([1, 2, 3]) |> Cursor.to_list() == [1, 2, 3]
    assert Cursor.new(1..3) |> Cursor.to_list() == [1, 2, 3]
    assert Cursor.new(Stream.map([1, 2, 3], & &1)) |> Cursor.to_list() == [1, 2, 3]
  end

  test "close/1 triggers a Stream.resource/3-backed source's own after_fun, even mid-stream" do
    {:ok, agent} = Agent.start_link(fn -> false end)

    stream =
      Stream.resource(
        fn -> :the_resource end,
        fn
          :the_resource -> {[1, 2, 3, 4, 5], :exhausted}
          :exhausted -> {:halt, :exhausted}
        end,
        fn _state -> Agent.update(agent, fn _ -> true end) end
      )

    cursor = Cursor.new(stream)
    assert {:ok, 1, cursor} = Cursor.next(cursor)
    refute Agent.get(agent, & &1)

    assert :ok = Cursor.close(cursor)
    assert Agent.get(agent, & &1)
  end

  test "merely abandoning a cursor (no close/1) does NOT run after_fun -- the exact leak close/1 exists to prevent" do
    {:ok, agent} = Agent.start_link(fn -> false end)

    stream =
      Stream.resource(
        fn -> :the_resource end,
        fn
          :the_resource -> {[1, 2, 3], :exhausted}
          :exhausted -> {:halt, :exhausted}
        end,
        fn _state -> Agent.update(agent, fn _ -> true end) end
      )

    cursor = Cursor.new(stream)
    assert {:ok, 1, _cursor} = Cursor.next(cursor)
    # No close/1 call -- confirms the leak close/1 is meant to fix is real.
    refute Agent.get(agent, & &1)
  end

  test "close/1 on an already-exhausted cursor is a safe no-op" do
    cursor = Cursor.new([])
    :done = Cursor.next(cursor)
    assert :ok = Cursor.close(cursor)
  end

  describe "a composed Stream stage that halts the source early (Stream.take/2)" do
    test "the final allowed element is still emitted, not silently dropped" do
      # Real regression: `Stream.take/2`, on its own last allowed
      # element, signals `{:halted, elem}` rather than `{:suspended,
      # elem, continuation}` -- `next/1` used to treat every
      # `{:halted, _}` as "no data", so this returned `[1]`, not
      # `[1, 2]`.
      assert Cursor.to_list(Cursor.new(Stream.take([1, 2, 3, 4], 2))) == [1, 2]
    end

    test "a genuine nil element right before the halt is emitted, not mistaken for the disambiguation sentinel" do
      assert Cursor.to_list(Cursor.new(Stream.take([nil, 1, 2], 1))) == [nil]
    end

    test "Stream.take_while/2's own rejecting halt (no new element at all) still terminates cleanly" do
      assert Cursor.to_list(Cursor.new(Stream.take_while([1, 2, 3, 4, 5], &(&1 < 3)))) == [1, 2]
    end

    test "a filter+drop+take composition still yields exactly what Enum.to_list/1 would" do
      stream = [1, 2, 3, 4, 5] |> Stream.filter(&(&1 != 2)) |> Stream.drop(1) |> Stream.take(2)
      assert Cursor.to_list(Cursor.new(stream)) == Enum.to_list(stream)
    end
  end
end
