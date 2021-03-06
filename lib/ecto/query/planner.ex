defmodule Ecto.Query.Planner do
  # Normalizes a query and its parameters.
  @moduledoc false

  alias Ecto.Query.SelectExpr
  alias Ecto.Query.JoinExpr

  if map_size(%Ecto.Query{}) != 17 do
    raise "Ecto.Query match out of date in builder"
  end

  @doc """
  Plans the query for execution.

  Planning happens in multiple steps:

    1. First the query is prepared by retrieving
       its cache key, casting and merging parameters

    2. Then a cache lookup is done, if the query is
       cached, we are done

    3. If there is no cache, we need to actually
       normalize and validate the query, asking the
       adapter to prepare it

    4. The query is sent to the adapter to be generated

  ## Cache

  All entries in the query, except the preload and sources
  field, should be part of the cache key.

  The cache value is the compiled query by the adapter
  along-side the select expression.
  """
  def query(query, operation, repo, adapter) do
    {query, params, key} = prepare(query, operation, adapter)
    if key == :nocache do
      {_, select, prepared} = query_without_cache(query, operation, adapter)
      {build_meta(query, select), {:nocache, prepared}, params}
    else
      query_with_cache(query, operation, repo, adapter, key, params)
    end
  end

  defp query_with_cache(query, operation, repo, adapter, key, params) do
    case query_lookup(query, operation, repo, adapter, repo, key) do
      {:nocache, select, prepared} ->
        {build_meta(query, select), {:nocache, prepared}, params}
      {_, :cached, select, cached} ->
        {build_meta(query, select), {:cached, cached}, params}
      {_, :cache, select, prepared} ->
        update = &cache_update(repo, key, &1)
        {build_meta(query, select), {:cache, update, prepared}, params}
    end
  end

  defp query_lookup(query, operation, repo, adapter, repo, key) do
    try do
      :ets.lookup(repo, key)
    rescue
      ArgumentError ->
        raise ArgumentError,
          "repo #{inspect repo} is not started, please ensure it is part of your supervision tree"
    else
      [term] -> term
      [] -> query_prepare(query, operation, adapter, repo, key)
    end
  end

  defp query_prepare(query, operation, adapter, repo, key) do
    case query_without_cache(query, operation, adapter) do
      {:cache, select, prepared} ->
        elem = {key, :cache, select, prepared}
        cache_insert(repo, key, elem)
      {:nocache, _, _} = nocache ->
        nocache
    end
  end

  defp cache_insert(repo, key, elem) do
    case :ets.insert_new(repo, elem) do
      true ->
        elem
      false ->
        [elem] = :ets.lookup(repo, key)
        elem
    end
  end

  defp cache_update(repo, key, cached) do
    _ = :ets.update_element(repo, key, [{2, :cached}, {4, cached}])
    :ok
  end

  defp query_without_cache(query, operation, adapter) do
    %{select: select} = query = normalize(query, operation, adapter)
    {cache, prepared} = adapter.prepare(operation, query)
    {cache, select, prepared}
  end

  defp build_meta(%{prefix: prefix, sources: sources, assocs: assocs, preloads: preloads},
                  %{expr: select, fields: fields}) do
    %{prefix: prefix, sources: sources, fields: fields,
      assocs: assocs, preloads: preloads, select: select}
  end
  defp build_meta(%{prefix: prefix, sources: sources, assocs: assocs, preloads: preloads},
                  nil) do
    %{prefix: prefix, sources: sources, fields: nil,
      assocs: assocs, preloads: preloads, select: nil}
  end

  @doc """
  Prepares the query for cache.

  This means all the parameters from query expressions are
  merged into a single value and their entries are prunned
  from the query.

  This function is called by the backend before invoking
  any cache mechanism.
  """
  def prepare(query, operation, adapter) do
    query
    |> prepare_sources(adapter)
    |> prepare_assocs
    |> prepare_cache(operation, adapter)
  rescue
    e ->
      # Reraise errors so we ignore the planner inner stacktrace
      reraise e
  end

  @doc """
  Prepare all sources, by traversing and expanding joins.
  """
  def prepare_sources(%{from: from} = query, adapter) do
    from = from || error!(query, "query must have a from expression")
    from = prepare_source(query, from, adapter)
    {joins, sources, tail_sources} = prepare_joins(query, [from], length(query.joins), adapter)
    %{query | from: from, joins: joins |> Enum.reverse,
              sources: (tail_sources ++ sources) |> Enum.reverse |> List.to_tuple()}
  end

  defp prepare_source(query, %Ecto.SubQuery{query: inner_query} = subquery, adapter) do
    try do
      {inner_query, params, key} = prepare(inner_query, :all, adapter)

      # The only reason we call normalize_select here is because
      # subquery_types validates a specific format in a way it
      # won't need to be modified again when normalized later on.
      inner_query = normalize_select(inner_query, :all)

      %{select: %{fields: fields, expr: select}, sources: sources} = inner_query
      %{subquery | query: inner_query, params: params, select: select, fields: fields,
                   sources: sources, types: subquery_types(inner_query), cache: key}
    rescue
      e -> raise Ecto.SubQueryError, query: query, exception: e
    end
  end

  defp prepare_source(_query, {nil, schema}, _adapter) when is_atom(schema) and schema != nil,
    do: {schema.__schema__(:source), schema}
  defp prepare_source(_query, {source, schema}, _adapter) when is_binary(source) and is_atom(schema),
    do: {source, schema}
  defp prepare_source(_query, {:fragment, _, _} = source, _adapter),
    do: source

  defp subquery_types(%{assocs: assocs, preloads: preloads} = query)
      when assocs != [] or preloads != [] do
    error!(query, "cannot preload associations in subquery")
  end
  defp subquery_types(%{select: %{fields: []}} = query) do
    error!(query, "subquery must select at least one source (t) or one field (t.field)")
  end
  defp subquery_types(%{select: %{fields: fields}} = query) do
    Enum.reduce(fields, [], fn
      {:&, _, [ix, [_|_] = fields, _]}, acc ->
        Enum.reduce(fields, acc, &add_subfield(query, &1, ix, &2))
      {{:., _, [{:&, _, [ix]}, field]}, _, []}, acc ->
        add_subfield(query, field, ix, acc)
      other, _acc ->
        error!(query, "subquery can only select sources (t) or fields (t.field), got: `#{Macro.to_string(other)}`")
    end) |> Enum.reverse()
  end

  defp add_subfield(query, field, ix, fields) do
    case Keyword.get(fields, field, ix) do
      ^ix -> [{field, ix}|fields]
      prev_ix ->
        sources = query.sources
        error!(query, "`#{field}` is selected from two different sources in subquery: " <>
                      "`#{inspect elem(sources, prev_ix)}` and `#{inspect elem(sources, ix)}`")
    end
  end

  defp prepare_joins(query, sources, offset, adapter) do
    prepare_joins(query.joins, query, [], sources, [], 1, offset, adapter)
  end

  defp prepare_joins([%JoinExpr{assoc: {ix, assoc}, qual: qual, on: on} = join|t],
                     query, joins, sources, tail_sources, counter, offset, adapter) do
    schema =
      case Enum.fetch!(Enum.reverse(sources), ix) do
        {source, nil} ->
          error! query, join, "cannot perform association join on #{inspect source} " <>
                              "because it does not have a schema"
        {_, schema} ->
          schema
        _ ->
          error! query, join, "can only perform association joins on sources with a schema"
      end

    refl = schema.__schema__(:association, assoc)

    unless refl do
      error! query, join, "could not find association `#{assoc}` on schema #{inspect schema}"
    end

    # If we have the following join:
    #
    #     from p in Post,
    #       join: p in assoc(p, :comments)
    #
    # The callback below will return a query that contains only
    # joins in a way it starts with the Post and ends in the
    # Comment.
    #
    # This means we need to rewrite the joins below to properly
    # shift the &... identifier in a way that:
    #
    #    &0         -> becomes assoc ix
    #    &LAST_JOIN -> becomes counter
    #
    # All values in the middle should be shifted by offset,
    # all values after join are already correct.
    child = refl.__struct__.joins_query(refl)
    last_ix = length(child.joins)
    source_ix = counter

    {child_joins, child_sources, child_tail} =
      prepare_joins(child, [child.from], offset + last_ix - 1, adapter)

    # Rewrite joins indexes as mentioned above
    child_joins = Enum.map(child_joins, &rewrite_join(&1, qual, ix, last_ix, source_ix, offset))

    # Drop the last resource which is the association owner (it is reversed)
    child_sources = Enum.drop(child_sources, -1)

    [current_source|child_sources] = child_sources
    child_sources = child_tail ++ child_sources

    prepare_joins(t, query, attach_on(child_joins, on) ++ joins, [current_source|sources],
                  child_sources ++ tail_sources, counter + 1, offset + length(child_sources), adapter)
  end

  defp prepare_joins([%JoinExpr{source: source} = join|t],
                     query, joins, sources, tail_sources, counter, offset, adapter) do
    source = prepare_source(query, source, adapter)
    join = %{join | source: source, ix: counter}
    prepare_joins(t, query, [join|joins], [source|sources], tail_sources, counter + 1, offset, adapter)
  end

  defp prepare_joins([], _query, joins, sources, tail_sources, _counter, _offset, _adapter) do
    {joins, sources, tail_sources}
  end

  defp attach_on(joins, %{expr: true}) do
    joins
  end
  defp attach_on([h|t], %{expr: expr}) do
    h =
      update_in h.on.expr, fn
        true    -> expr
        current -> {:and, [], [current, expr]}
      end
    [h|t]
  end

  defp rewrite_join(%{on: on, ix: join_ix} = join, qual, ix, last_ix, source_ix, inc_ix) do
    on = update_in on.expr, fn expr ->
      Macro.prewalk expr, fn
        {:&, meta, [join_ix]} ->
          {:&, meta, [rewrite_ix(join_ix, ix, last_ix, source_ix, inc_ix)]}
        other ->
          other
      end
    end

    %{join | on: on, qual: qual,
             ix: rewrite_ix(join_ix, ix, last_ix, source_ix, inc_ix)}
  end

  # We need to replace the source by the one from the assoc
  defp rewrite_ix(0, ix, _last_ix, _source_ix, _inc_x), do: ix

  # The last entry will have the current source index
  defp rewrite_ix(last_ix, _ix, last_ix, source_ix, _inc_x), do: source_ix

  # All above last are already correct
  defp rewrite_ix(join_ix, _ix, last_ix, _source_ix, _inc_ix) when join_ix > last_ix, do: join_ix

  # All others need to be incremented by the offset sources
  defp rewrite_ix(join_ix, _ix, _last_ix, _source_ix, inc_ix), do: join_ix + inc_ix

  @doc """
  Prepare the parameters by merging and casting them according to sources.
  """
  def prepare_cache(query, operation, adapter) do
    {query, {cache, params}} =
      traverse_exprs(query, operation, {[], []}, &{&3, merge_cache(&1, &2, &3, &4, adapter)})
    {query, Enum.reverse(params), finalize_cache(query, operation, cache)}
  end

  defp merge_cache(:from, _query, expr, {cache, params}, _adapter) do
    {key, params} = source_cache(expr, params)
    {merge_cache(key, cache, key != :nocache), params}
  end

  defp merge_cache(kind, query, expr, {cache, params}, adapter)
      when kind in ~w(select distinct limit offset)a do
    if expr do
      {params, cacheable?} = cast_and_merge_params(kind, query, expr, params, adapter)
      {merge_cache({kind, expr.expr}, cache, cacheable?), params}
    else
      {cache, params}
    end
  end

  defp merge_cache(kind, query, exprs, {cache, params}, adapter)
      when kind in ~w(where update group_by having order_by)a do
    {expr_cache, {params, cacheable?}} =
      Enum.map_reduce exprs, {params, true}, fn expr, {params, cacheable?} ->
        {params, current_cacheable?} = cast_and_merge_params(kind, query, expr, params, adapter)
        {expr.expr, {params, cacheable? and current_cacheable?}}
      end

    case expr_cache do
      [] -> {cache, params}
      _  -> {merge_cache({kind, expr_cache}, cache, cacheable?), params}
    end
  end

  defp merge_cache(:join, query, exprs, {cache, params}, adapter) do
    {expr_cache, {params, cacheable?}} =
      Enum.map_reduce exprs, {params, true}, fn
        %JoinExpr{on: on, qual: qual, source: source} = join, {params, cacheable?} ->
          {key, params} = source_cache(source, params)
          {params, join_cacheable?} = cast_and_merge_params(:join, query, join, params, adapter)
          {params, on_cacheable?} = cast_and_merge_params(:join, query, on, params, adapter)
          {{qual, key, on.expr},
           {params, cacheable? and join_cacheable? and on_cacheable? and key != :nocache}}
      end

    case expr_cache do
      [] -> {cache, params}
      _  -> {merge_cache({:join, expr_cache}, cache, cacheable?), params}
    end
  end

  defp cast_and_merge_params(kind, query, expr, params, adapter) do
    Enum.reduce expr.params, {params, true}, fn
      {v, {:in_spread, type}}, {acc, _cacheable?} ->
        {unfold_in(cast_param(kind, query, expr, v, {:array, type}, adapter), acc), false}
      {v, type}, {acc, cacheable?} ->
        {[cast_param(kind, query, expr, v, type, adapter)|acc], cacheable?}
    end
  end

  defp merge_cache(_left, _right, false),  do: :nocache
  defp merge_cache(_left, :nocache, true), do: :nocache
  defp merge_cache(left, right, true),     do: [left|right]

  defp finalize_cache(_query, _operation, :nocache) do
    :nocache
  end

  defp finalize_cache(%{assocs: assocs, prefix: prefix, lock: lock, select: select},
                      operation, cache) do
    cache =
      case select do
        %{take: take} when take != %{} ->
          [take: take] ++ cache
        _ ->
          cache
      end

    if assocs && assocs != [] do
      cache = [assocs: assocs] ++ cache
    end

    if prefix do
      cache = [prefix: prefix] ++ cache
    end

    if lock do
      cache = [lock: lock] ++ cache
    end

    [operation|cache]
  end

  defp source_cache({_, nil} = source, params),
    do: {source, params}
  defp source_cache({bin, model}, params),
    do: {{bin, model, model.__schema__(:hash)}, params}
  defp source_cache({:fragment, _, _} = source, params),
    do: {source, params}
  defp source_cache(%Ecto.SubQuery{params: inner, cache: key}, params),
    do: {key, Enum.reverse(inner, params)}

  defp cast_param(kind, query, expr, v, type, adapter) do
    type = type!(kind, query, expr, type)

    try do
      case cast_param(kind, type, v, adapter) do
        {:ok, v} -> v
        {:error, error} -> error! query, expr, error
      end
    catch
      :error, %Ecto.QueryError{} = e ->
        raise Ecto.CastError, value: v, type: type, message: Exception.message(e)
    end
  end

  defp cast_param(kind, type, nil, _adapter) when kind != :update do
    {:error, "value `nil` in `#{kind}` cannot be cast to type #{inspect type} " <>
             "(if you want to check for nils, use is_nil/1 instead)"}
  end

  defp cast_param(kind, type, v, adapter) do
    with {:ok, type} <- normalize_param(kind, type, v),
         {:ok, v} <- cast_param(kind, type, v),
         do: dump_param(adapter, type, v)
  end

  defp unfold_in(%Ecto.Query.Tagged{value: value, type: {:array, type}}, acc),
    do: unfold_in(value, type, acc)
  defp unfold_in(value, acc) when is_list(value),
    do: Enum.reverse(value, acc)

  defp unfold_in([h|t], type, acc),
    do: unfold_in(t, type, [%Ecto.Query.Tagged{value: h, type: type}|acc])
  defp unfold_in([], _type, acc),
    do: acc

  @doc """
  Prepare association fields found in the query.
  """
  def prepare_assocs(query) do
    prepare_assocs(query, 0, query.assocs)
    query
  end

  defp prepare_assocs(_query, _ix, []), do: :ok
  defp prepare_assocs(query, ix, assocs) do
    # We validate the schema exists when preparing joins above
    {_, parent_schema} = elem(query.sources, ix)

    Enum.each assocs, fn {assoc, {child_ix, child_assocs}} ->
      refl = parent_schema.__schema__(:association, assoc)

      unless refl do
        error! query, "field `#{inspect parent_schema}.#{assoc}` " <>
                      "in preload is not an association"
      end

      case find_source_expr(query, child_ix) do
        %JoinExpr{qual: qual} when qual in [:inner, :left] ->
          :ok
        %JoinExpr{qual: qual} ->
          error! query, "association `#{inspect parent_schema}.#{assoc}` " <>
                        "in preload requires an inner or left join, got #{qual} join"
        _ ->
          :ok
      end

      prepare_assocs(query, child_ix, child_assocs)
    end
  end

  defp find_source_expr(query, 0) do
    query.from
  end

  defp find_source_expr(query, ix) do
    Enum.find(query.joins, & &1.ix == ix)
  end

  @doc """
  Normalizes the query.

  After the query was prepared and there is no cache
  entry, we need to update its interpolations and check
  its fields and associations exist and are valid.
  """
  def normalize(query, operation, adapter) do
    query
    |> normalize(operation, adapter, 0)
    |> elem(0)
    |> normalize_select(operation)
  rescue
    e ->
      # Reraise errors so we ignore the planner inner stacktrace
      reraise e
  end

  defp normalize(query, operation, adapter, counter) do
    case operation do
      :all ->
        assert_no_update!(query, operation)
      :update_all ->
        assert_update!(query, operation)
        assert_only_filter_expressions!(query, operation)
      :delete_all ->
        assert_no_update!(query, operation)
        assert_only_filter_expressions!(query, operation)
    end

    traverse_exprs(query, operation, counter,
                   &validate_and_increment(&1, &2, &3, &4, operation, adapter))
  end

  defp validate_and_increment(:from, query, %Ecto.SubQuery{}, _counter, kind, _adapter) when kind != :all do
    error! query, "`#{kind}` does not allow subqueries in `from`"
  end
  defp validate_and_increment(:from, query, expr, counter, _kind, adapter) do
    validate_and_increment_each(:from, query, expr, expr, counter, adapter)
  end

  defp validate_and_increment(kind, query, expr, counter, _operation, adapter)
      when kind in ~w(select distinct limit offset)a do
    if expr do
      validate_and_increment_each(kind, query, expr, counter, adapter)
    else
      {nil, counter}
    end
  end

  defp validate_and_increment(kind, query, exprs, counter, _operation, adapter)
      when kind in ~w(where group_by having order_by update)a do
    {exprs, counter} =
      Enum.reduce(exprs, {[], counter}, fn
        %{expr: []}, {list, acc} ->
          {list, acc}
        expr, {list, acc} ->
          {expr, acc} = validate_and_increment_each(kind, query, expr, acc, adapter)
          {[expr|list], acc}
      end)
    {Enum.reverse(exprs), counter}
  end

  defp validate_and_increment(:join, query, exprs, counter, _operation, adapter) do
    Enum.map_reduce exprs, counter, fn join, acc ->
      {source, acc} = validate_and_increment_each(:join, query, join, join.source, acc, adapter)
      {on, acc} = validate_and_increment_each(:join, query, join.on, acc, adapter)
      {%{join | on: on, source: source, params: nil}, acc}
    end
  end

  defp validate_and_increment_each(kind, query, expr, counter, adapter) do
    {inner, acc} = validate_and_increment_each(kind, query, expr, expr.expr, counter, adapter)
    {%{expr | expr: inner, params: nil}, acc}
  end

  defp validate_and_increment_each(_kind, query, _expr,
                                   %Ecto.SubQuery{query: inner_query} = subquery, counter, adapter) do
    try do
      {inner_query, counter} = normalize(inner_query, :all, adapter, counter)
      {%{subquery | query: inner_query, params: nil}, counter}
    rescue
      e -> raise Ecto.SubQueryError, query: query, exception: e
    end
  end

  defp validate_and_increment_each(kind, query, expr, ast, counter, adapter) do
    Macro.prewalk ast, counter, fn
      {:in, in_meta, [left, {:^, meta, [param]}]}, acc ->
        {right, acc} = validate_in(meta, expr, param, acc)
        {{:in, in_meta, [left, right]}, acc}

      {:^, meta, [ix]}, acc when is_integer(ix) ->
        {{:^, meta, [acc]}, acc + 1}

      {:type, _, [{:^, meta, [ix]}, _expr]}, acc when is_integer(ix) ->
        {_, t} = Enum.fetch!(expr.params, ix)
        type   = type!(kind, query, expr, t)
        {%Ecto.Query.Tagged{value: {:^, meta, [acc]}, tag: type,
                            type: Ecto.Type.type(type)}, acc + 1}

      %Ecto.Query.Tagged{value: v, type: type}, acc ->
        {dump_param(kind, query, expr, v, type, adapter), acc}

      other, acc ->
        {other, acc}
    end
  end

  defp dump_param(kind, query, expr, v, type, adapter) do
    type = type!(kind, query, expr, type)

    case dump_param(kind, type, v, adapter) do
      {:ok, v} ->
        v
      {:error, error} ->
        error = error <> ". Or the value is incompatible or it must be " <>
                         "interpolated (using ^) so it may be cast accordingly"
        error! query, expr, error
    end
  end

  # Exceptionally allow decimal casting for support on interval operations.
  defp dump_param(kind, :decimal, v, adapter) do
    cast_param(kind, :decimal, v, adapter)
  end
  defp dump_param(kind, type, v, adapter) do
    with {:ok, type} <- normalize_param(kind, type, v),
         do: dump_param(adapter, type, v)
  end

  defp validate_in(meta, expr, param, acc) do
    {v, _t} = Enum.fetch!(expr.params, param)
    length  = length(v)

    case length do
      0 -> {[], acc}
      _ -> {{:^, meta, [acc, length]}, acc + length}
    end
  end

  defp normalize_select(query, operation) when operation in [:update_all, :delete_all] do
    query
  end
  defp normalize_select(%{select: nil} = query, _operation) do
    select = %SelectExpr{expr: {:&, [], [0]}, line: __ENV__.line, file: __ENV__.file}
    %{query | select: normalize_fields(query, select)}
  end
  defp normalize_select(%{select: %{fields: nil} = select} = query, _operation) do
    %{query | select: normalize_fields(query, select)}
  end
  defp normalize_select(query, _operation) do
    query
  end

  defp normalize_fields(%{assocs: [], preloads: []} = query,
                        %{take: take, expr: expr} = select) do
    {fields, from} = collect_fields(expr, query, take, :error)

    fields =
      case from do
        {:ok, from} -> [{:&, [], [0, from, from && length(from)]}|fields]
        :error -> fields
      end

    %{select | fields: fields}
  end

  defp normalize_fields(%{assocs: assocs, sources: sources} = query,
                        %{take: take, expr: expr} = select) do
    {fields, from} = collect_fields(expr, query, take, :error)

    case from do
      {:ok, from} ->
        assocs = collect_assocs(sources, assocs)
        fields = [{:&, [], [0, from, from && length(from)]}|assocs] ++ fields
        %{select | fields: fields}
      :error ->
        error! query, "the binding used in `from` must be selected in `select` when using `preload`"
    end
  end

  defp collect_fields({:&, _, [0]}, query, take, :error) do
    fields = take!(query, take, 0)
    {[], {:ok, fields}}
  end
  defp collect_fields({:&, _, [0]}, _query, _take, from) do
    {[], from}
  end
  defp collect_fields({:&, _, [ix]}, query, take, from) do
    fields = take!(query, take, ix)
    {[{:&, [], [ix, fields, fields && length(fields)]}], from}
  end

  defp collect_fields({agg, meta, [{{:., _, [{:&, _, [ix]}, field]}, _, []}] = args},
                      %{select: select} = query, _take, from) when agg in ~w(avg min max sum)a do
    type = source_type!(:select, query, select, ix, field)
    {[{agg, [ecto_type: type] ++ meta, args}], from}
  end

  defp collect_fields({{:., _, [{:&, _, [ix]}, field]} = dot, meta, []},
                      %{select: select} = query, _take, from) do
    type = source_type!(:select, query, select, ix, field)
    {[{dot, [ecto_type: type] ++ meta, []}], from}
  end

  defp collect_fields({left, right}, query, take, from) do
    {left, from}  = collect_fields(left, query, take, from)
    {right, from} = collect_fields(right, query, take, from)
    {left ++ right, from}
  end
  defp collect_fields({:{}, _, elems}, query, take, from),
    do: collect_fields(elems, query, take, from)
  defp collect_fields({:%{}, _, pairs}, query, take, from),
    do: collect_fields(pairs, query, take, from)
  defp collect_fields(list, query, take, from) when is_list(list),
    do: Enum.flat_map_reduce(list, from, &collect_fields(&1, query, take, &2))
  defp collect_fields(expr, _query, _take, from) when is_atom(expr) or is_binary(expr) or is_number(expr),
    do: {[], from}
  defp collect_fields(expr, _query, _take, from),
    do: {[expr], from}

  defp collect_assocs(sources, [{_assoc, {ix, children}}|tail]) do
    fields = source_fields!(elem(sources, ix))
    [{:&, [], [ix, fields, fields && length(fields)]}] ++
      collect_assocs(sources, children) ++
      collect_assocs(sources, tail)
  end
  defp collect_assocs(_sources, []) do
    []
  end

  defp take!(%{sources: sources} = query, take, ix) do
    source = elem(sources, ix)
    case Map.fetch(take, ix) do
      {:ok, value} when is_tuple(source) ->
        value
      {:ok, _} ->
        error! query, "cannot take multiple fields on fragment or subquery sources"
      :error ->
        source_fields!(source)
    end
  end

  defp source_fields!(source) do
    case source do
      %Ecto.SubQuery{types: types} -> Keyword.keys(types)
      {_, nil} -> nil
      {_, schema} -> schema.__schema__(:fields)
    end
  end

  ## Helpers

  # Traverse all query components with expressions.
  # Therefore from, preload, assocs and lock are not traversed.
  defp traverse_exprs(original, operation, acc, fun) do
    query = original

    if operation == :update_all do
      {updates, acc} = fun.(:update, original, original.updates, acc)
      query = %{query | updates: updates}
    end

    {select, acc} = fun.(:select, original, original.select, acc)
    query = %{query | select: select}

    {from, acc} = fun.(:from, original, original.from, acc)
    query = %{query | from: from}

    {distinct, acc} = fun.(:distinct, original, original.distinct, acc)
    query = %{query | distinct: distinct}

    {joins, acc} = fun.(:join, original, original.joins, acc)
    query = %{query | joins: joins}

    {wheres, acc} = fun.(:where, original, original.wheres, acc)
    query = %{query | wheres: wheres}

    {group_bys, acc} = fun.(:group_by, original, original.group_bys, acc)
    query = %{query | group_bys: group_bys}

    {havings, acc} = fun.(:having, original, original.havings, acc)
    query = %{query | havings: havings}

    {order_bys, acc} = fun.(:order_by, original, original.order_bys, acc)
    query = %{query | order_bys: order_bys}

    {limit, acc} = fun.(:limit, original, original.limit, acc)
    query = %{query | limit: limit}

    {offset, acc} = fun.(:offset, original, original.offset, acc)
    {%{query | offset: offset}, acc}
  end

  defp source_type!(_kind, _query, _expr, nil, _field), do: :any
  defp source_type!(kind, query, expr, ix, field) when is_integer(ix) do
    case elem(query.sources, ix) do
      {_, schema} ->
        source_type!(kind, query, expr, schema, field)
      {:fragment, _, _} ->
        :any
      %Ecto.SubQuery{types: types, query: inner_query} ->
        case Keyword.fetch(types, field) do
          {:ok, ix} -> source_type!(kind, inner_query, expr, ix, field)
          :error    -> error!(query, expr, "field `#{field}` does not exist in subquery")
        end
    end
  end
  defp source_type!(kind, query, expr, schema, field) when is_atom(schema) do
    if type = schema.__schema__(:type, field) do
      type
    else
      error! query, expr, "field `#{inspect schema}.#{field}` in `#{kind}` " <>
                          "does not exist in the schema"
    end
  end

  defp type!(kind, query, expr, {composite, {ix, field}}) when is_integer(ix) do
    {composite, source_type!(kind, query, expr, ix, field)}
  end
  defp type!(kind, query, expr, {ix, field}) when is_integer(ix) do
    source_type!(kind, query, expr, ix, field)
  end
  defp type!(_kind, _query, _expr, type) do
    type
  end

  defp normalize_param(_kind, {:in_array, {:array, type}}, _value) do
    {:ok, type}
  end
  defp normalize_param(_kind, {:in_array, :any}, _value) do
    {:ok, :any}
  end
  defp normalize_param(kind, {:in_array, other}, value) do
    {:error, "value `#{inspect value}` in `#{kind}` expected to be part of an array " <>
             "but matched type is #{inspect other}"}
  end
  defp normalize_param(_kind, type, _value) do
    {:ok, type}
  end

  defp cast_param(kind, type, v) do
    case Ecto.Type.cast(type, v) do
      {:ok, v} ->
        {:ok, v}
      :error ->
        {:error, "value `#{inspect v}` in `#{kind}` cannot be cast to type #{inspect type}"}
    end
  end

  defp dump_param(adapter, type, v) do
    case Ecto.Type.adapter_dump(adapter, type, v) do
      {:ok, v} -> {:ok, v}
      :error   -> {:error, "cannot dump value `#{inspect v}` to type #{inspect type}"}
    end
  end

  defp assert_update!(%Ecto.Query{updates: updates} = query, operation) do
    changes =
      Enum.reduce(updates, %{}, fn update, acc ->
        Enum.reduce(update.expr, acc, fn {_op, kw}, acc ->
          Enum.reduce(kw, acc, fn {k, v}, acc ->
            Map.update(acc, k, v, fn _ ->
              error! query, "duplicate field `#{k}` for `#{operation}`"
            end)
          end)
        end)
      end)

    if changes == %{} do
      error! query, "`#{operation}` requires at least one field to be updated"
    end
  end

  defp assert_no_update!(query, operation) do
    case query do
      %Ecto.Query{updates: []} -> query
      _ ->
        error! query, "`#{operation}` does not allow `update` expressions"
    end
  end

  defp assert_only_filter_expressions!(query, operation) do
    case query do
      %Ecto.Query{select: nil, order_bys: [], limit: nil, offset: nil,
                  group_bys: [], havings: [], preloads: [], assocs: [],
                  distinct: nil, lock: nil} ->
        query
      _ ->
        error! query, "`#{operation}` allows only `where` and `join` expressions"
    end
  end

  defp reraise(exception) do
    reraise exception, Enum.reject(System.stacktrace, &match?({__MODULE__, _, _, _}, &1))
  end

  defp error!(query, message) do
    raise Ecto.QueryError, message: message, query: query
  end

  defp error!(query, expr, message) do
    raise Ecto.QueryError, message: message, query: query, file: expr.file, line: expr.line
  end
end
