defmodule Librarian.Vault.GraphLayout do
  @moduledoc """
  Deterministic Fruchterman–Reingold force layout. Initial positions are
  hashed from node ids (no RNG state), so the same graph always lays out the
  same way. O(n²) per iteration — callers cap the node count.
  """

  @iterations 120

  def layout(node_ids, edge_pairs, width \\ 1200.0, height \\ 800.0)
  def layout([], _edge_pairs, _width, _height), do: %{}

  def layout(node_ids, edge_pairs, width, height) do
    k = :math.sqrt(width * height / length(node_ids))

    pos =
      Map.new(node_ids, fn id ->
        {id, {seeded(id, 0) * width, seeded(id, 1) * height}}
      end)

    Enum.reduce(1..@iterations, pos, fn iter, pos ->
      temp = max(width / 10.0 * (1.0 - iter / @iterations), 1.0)
      step(pos, node_ids, edge_pairs, k, temp, width, height)
    end)
  end

  defp seeded(id, salt) do
    (:erlang.phash2({id, salt}, 10_000) + 1) / 10_001
  end

  defp step(pos, ids, edges, k, temp, width, height) do
    disp = Map.new(ids, &{&1, {0.0, 0.0}})

    disp =
      reduce_pairs(ids, disp, fn a, b, disp ->
        {dx, dy, dist} = delta(pos[a], pos[b])
        f = k * k / dist

        disp
        |> nudge(a, dx / dist * f, dy / dist * f)
        |> nudge(b, -dx / dist * f, -dy / dist * f)
      end)

    disp =
      Enum.reduce(edges, disp, fn {source, target}, disp ->
        case {pos[source], pos[target]} do
          {ps, pt} when ps != nil and pt != nil ->
            {dx, dy, dist} = delta(ps, pt)
            f = dist * dist / k

            disp
            |> nudge(source, -dx / dist * f, -dy / dist * f)
            |> nudge(target, dx / dist * f, dy / dist * f)

          _ ->
            disp
        end
      end)

    Map.new(pos, fn {id, {x, y}} ->
      {dx, dy} = disp[id]
      len = max(:math.sqrt(dx * dx + dy * dy), 0.001)
      scale = min(len, temp) / len
      {id, {clamp(x + dx * scale, width), clamp(y + dy * scale, height)}}
    end)
  end

  defp reduce_pairs([], acc, _fun), do: acc

  defp reduce_pairs([a | rest], acc, fun) do
    acc = Enum.reduce(rest, acc, fn b, acc -> fun.(a, b, acc) end)
    reduce_pairs(rest, acc, fun)
  end

  defp delta({ax, ay}, {bx, by}) do
    dx = ax - bx
    dy = ay - by
    {dx, dy, max(:math.sqrt(dx * dx + dy * dy), 0.01)}
  end

  defp nudge(disp, id, dx, dy) do
    Map.update!(disp, id, fn {x, y} -> {x + dx, y + dy} end)
  end

  defp clamp(v, bound), do: v |> max(10.0) |> min(bound - 10.0)
end
