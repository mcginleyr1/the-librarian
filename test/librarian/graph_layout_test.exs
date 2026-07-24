defmodule Librarian.GraphLayoutTest do
  use ExUnit.Case, async: true

  alias Librarian.Vault.GraphLayout

  test "empty graph lays out to an empty map" do
    assert GraphLayout.layout([], []) == %{}
  end

  test "positions stay within bounds and are deterministic" do
    ids = Enum.to_list(1..30)
    edges = Enum.map(1..29, &{&1, &1 + 1})

    pos = GraphLayout.layout(ids, edges, 1200.0, 800.0)

    assert map_size(pos) == 30

    for {_id, {x, y}} <- pos do
      assert x >= 10.0 and x <= 1190.0
      assert y >= 10.0 and y <= 790.0
    end

    assert pos == GraphLayout.layout(ids, edges, 1200.0, 800.0)
  end

  test "connected nodes end up closer than the layout diagonal" do
    # a tight pair vs an isolated third node
    pos = GraphLayout.layout([1, 2, 3], [{1, 2}], 1200.0, 800.0)

    dist = fn a, b ->
      {ax, ay} = pos[a]
      {bx, by} = pos[b]
      :math.sqrt((ax - bx) ** 2 + (ay - by) ** 2)
    end

    assert dist.(1, 2) < dist.(1, 3)
    assert dist.(1, 2) < dist.(2, 3)
  end
end
