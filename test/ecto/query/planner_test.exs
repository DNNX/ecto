Code.require_file "../../../integration_test/support/types.exs", __DIR__

defmodule Ecto.Query.PlannerTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Ecto.Query.Planner
  alias Ecto.Query.JoinExpr

  defmodule Comment do
    use Ecto.Schema

    schema "comments" do
      field :text, :string
      field :temp, :string, virtual: true
      field :posted, Ecto.DateTime
      field :uuid, :binary_id
      belongs_to :post, Ecto.Query.PlannerTest.Post
      has_many :post_comments, through: [:post, :comments]
    end
  end

  defmodule Post do
    use Ecto.Schema

    @primary_key {:id, Custom.Permalink, []}
    schema "posts" do
      field :title, :string
      field :text, :string
      field :code, :binary
      field :posted, Ecto.DateTime
      field :visits, :integer
      field :links, {:array, Custom.Permalink}
      has_many :comments, Ecto.Query.PlannerTest.Comment
    end
  end

  defp prepare(query, operation \\ :all) do
    Planner.prepare(query, operation, Ecto.TestAdapter)
  end

  defp normalize(query, operation \\ :all) do
    normalize_with_params(query, operation) |> elem(0)
  end

  defp normalize_with_params(query, operation \\ :all) do
    {query, params, _key} = prepare(query, operation)
    {Planner.normalize(query, operation, Ecto.TestAdapter), params}
  end

  test "prepare: merges all parameters" do
    query =
      from p in Post,
        select: {p.title, ^"0"},
        join: c in Comment,
        on: c.text == ^"1",
        left_join: d in assoc(p, :comments),
        where: p.title == ^"2",
        group_by: p.title == ^"3",
        having: p.title == ^"4",
        order_by: [asc: fragment("?", ^"5")],
        limit: ^6,
        offset: ^7

    {_query, params, _key} = prepare(query)
    assert params == ["0", "1", "2", "3", "4", "5", 6, 7]
  end

  test "prepare: checks from" do
    assert_raise Ecto.QueryError, ~r"query must have a from expression", fn ->
      prepare(%Ecto.Query{})
    end
  end

  test "prepare: casts values" do
    {_query, params, _key} = prepare(Post |> where([p], p.id == ^"1"))
    assert params == [1]

    exception = assert_raise Ecto.CastError, fn ->
      prepare(Post |> where([p], p.title == ^nil))
    end

    assert Exception.message(exception) =~ "value `nil` in `where` cannot be cast to type :string"
    assert Exception.message(exception) =~ "where: p.title == ^nil"

    exception = assert_raise Ecto.CastError, fn ->
      prepare(Post |> where([p], p.title == ^1))
    end

    assert Exception.message(exception) =~ "value `1` in `where` cannot be cast to type :string"
    assert Exception.message(exception) =~ "where: p.title == ^1"
  end

  test "prepare: casts and dumps custom types" do
    datetime = %Ecto.DateTime{year: 2015, month: 1, day: 7, hour: 21, min: 18, sec: 13, usec: 0}
    {_query, params, _key} = prepare(Comment |> where([c], c.posted == ^datetime))
    assert params == [{{2015, 1, 7}, {21, 18, 13, 0}}]

    permalink = "1-hello-world"
    {_query, params, _key} = prepare(Post |> where([p], p.id == ^permalink))
    assert params == [1]
  end

  test "prepare: casts and dumps custom types to native ones" do
    datetime = %Ecto.DateTime{year: 2015, month: 1, day: 7, hour: 21, min: 18, sec: 13, usec: 0}
    {_query, params, _key} = prepare(Post |> where([p], p.posted == ^datetime))
    assert params == [{{2015, 1, 7}, {21, 18, 13, 0}}]
  end

  test "prepare: casts and dumps binary ids" do
    uuid = "00010203-0405-0607-0809-0a0b0c0d0e0f"
    {_query, params, _key} = prepare(Comment |> where([c], c.uuid == ^uuid))
    assert params == [%Ecto.Query.Tagged{type: :uuid,
                        value: <<0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15>>}]

    assert_raise Ecto.CastError,
                 ~r/cannot dump value `"00010203-0405-0607-0809"` to type :binary_id/, fn ->
      uuid = "00010203-0405-0607-0809"
      prepare(Comment |> where([c], c.uuid == ^uuid))
    end
  end

  test "prepare: casts and dumps custom types in left side of in-expressions" do
    permalink = "1-hello-world"
    {_query, params, _key} = prepare(Post |> where([p], ^permalink in p.links))
    assert params == [1]

    message = ~r"value `\"1-hello-world\"` in `where` expected to be part of an array but matched type is :string"
    assert_raise Ecto.CastError, message, fn ->
      prepare(Post |> where([p], ^permalink in p.text))
    end
  end

  test "prepare: casts and dumps custom types in right side of in-expressions" do
    datetime = %Ecto.DateTime{year: 2015, month: 1, day: 7, hour: 21, min: 18, sec: 13, usec: 0}
    {_query, params, _key} = prepare(Comment |> where([c], c.posted in ^[datetime]))
    assert params == [{{2015, 1, 7}, {21, 18, 13, 0}}]

    permalink = "1-hello-world"
    {_query, params, _key} = prepare(Post |> where([p], p.id in ^[permalink]))
    assert params == [1]

    datetime = %Ecto.DateTime{year: 2015, month: 1, day: 7, hour: 21, min: 18, sec: 13, usec: 0}
    {_query, params, _key} = prepare(Comment |> where([c], c.posted in [^datetime]))
    assert params == [{{2015, 1, 7}, {21, 18, 13, 0}}]

    permalink = "1-hello-world"
    {_query, params, _key} = prepare(Post |> where([p], p.id in [^permalink]))
    assert params == [1]

    {_query, params, _key} = prepare(Post |> where([p], p.code in [^"abcd"]))
    assert params == [%Ecto.Query.Tagged{tag: nil, type: :binary, value: "abcd"}]

    {_query, params, _key} = prepare(Post |> where([p], p.code in ^["abcd"]))
    assert params == [%Ecto.Query.Tagged{tag: nil, type: :binary, value: "abcd"}]
  end

  test "prepare: casts values on update_all" do
    {_query, params, _key} = prepare(Post |> update([p], set: [id: ^"1"]), :update_all)
    assert params == [1]

    {_query, params, _key} = prepare(Post |> update([p], set: [title: ^nil]), :update_all)
    assert params == [%Ecto.Query.Tagged{type: :string, value: nil}]

    {_query, params, _key} = prepare(Post |> update([p], set: [title: nil]), :update_all)
    assert params == []
  end

  test "prepare: joins" do
    query = from(p in Post, join: c in "comments") |> prepare |> elem(0)
    assert hd(query.joins).source == {"comments", nil}

    query = from(p in Post, join: c in Comment) |> prepare |> elem(0)
    assert hd(query.joins).source == {"comments", Comment}

    query = from(p in Post, join: c in {"post_comments", Comment}) |> prepare |> elem(0)
    assert hd(query.joins).source == {"post_comments", Comment}
  end

  test "prepare: joins associations" do
    query = from(p in Post, join: assoc(p, :comments)) |> prepare |> elem(0)
    assert %JoinExpr{on: on, source: source, assoc: nil, qual: :inner} = hd(query.joins)
    assert source == {"comments", Comment}
    assert Macro.to_string(on.expr) == "&1.post_id() == &0.id()"

    query = from(p in Post, left_join: assoc(p, :comments)) |> prepare |> elem(0)
    assert %JoinExpr{on: on, source: source, assoc: nil, qual: :left} = hd(query.joins)
    assert source == {"comments", Comment}
    assert Macro.to_string(on.expr) == "&1.post_id() == &0.id()"

    query = from(p in Post, left_join: c in assoc(p, :comments), on: p.title == c.text) |> prepare |> elem(0)
    assert %JoinExpr{on: on, source: source, assoc: nil, qual: :left} = hd(query.joins)
    assert source == {"comments", Comment}
    assert Macro.to_string(on.expr) == "&1.post_id() == &0.id() and &0.title() == &1.text()"
  end

  test "prepare: nested joins associations" do
    query = from(c in Comment, left_join: assoc(c, :post_comments)) |> prepare |> elem(0)
    assert {{"comments", _}, {"comments", _}, {"posts", _}} = query.sources
    assert [join1, join2] = query.joins
    assert Enum.map(query.joins, & &1.ix) == [2, 1]
    assert Macro.to_string(join1.on.expr) == "&2.id() == &0.post_id()"
    assert Macro.to_string(join2.on.expr) == "&1.post_id() == &2.id()"

    query = from(p in Comment, left_join: assoc(p, :post),
                               left_join: assoc(p, :post_comments)) |> prepare |> elem(0)
    assert {{"comments", _}, {"posts", _}, {"comments", _}, {"posts", _}} = query.sources
    assert [join1, join2, join3] = query.joins
    assert Enum.map(query.joins, & &1.ix) == [1, 3, 2]
    assert Macro.to_string(join1.on.expr) == "&1.id() == &0.post_id()"
    assert Macro.to_string(join2.on.expr) == "&3.id() == &0.post_id()"
    assert Macro.to_string(join3.on.expr) == "&2.post_id() == &3.id()"

    query = from(p in Comment, left_join: assoc(p, :post_comments),
                               left_join: assoc(p, :post)) |> prepare |> elem(0)
    assert {{"comments", _}, {"comments", _}, {"posts", _}, {"posts", _}} = query.sources
    assert [join1, join2, join3] = query.joins
    assert Enum.map(query.joins, & &1.ix) == [3, 1, 2]
    assert Macro.to_string(join1.on.expr) == "&3.id() == &0.post_id()"
    assert Macro.to_string(join2.on.expr) == "&1.post_id() == &3.id()"
    assert Macro.to_string(join3.on.expr) == "&2.id() == &0.post_id()"
  end

  test "prepare: cannot associate without schema" do
    query   = from(p in "posts", join: assoc(p, :comments))
    message = ~r"cannot perform association join on \"posts\" because it does not have a schema"

    assert_raise Ecto.QueryError, message, fn ->
      prepare(query)
    end
  end

  test "prepare: requires an association field" do
    query = from(p in Post, join: assoc(p, :title))

    assert_raise Ecto.QueryError, ~r"could not find association `title`", fn ->
      prepare(query)
    end
  end

  test "prepare: generates a cache key if appropriate" do
    {_query, _params, key} = prepare(from(Post, []))
    assert key == [:all, {"posts", Post, 112914533}]

    query = from(p in Post, select: 1, lock: "foo", where: is_nil(nil),
                            join: c in Comment, preload: :comments)
    {_query, _params, key} = prepare(%{query | prefix: "foo"})
    assert key == [:all,
                   {:lock, "foo"},
                   {:prefix, "foo"},
                   {:where, [{:is_nil, [], [nil]}]},
                   {:join, [{:inner, {"comments", Ecto.Query.PlannerTest.Comment, 53730846}, true}]},
                   {"posts", Ecto.Query.PlannerTest.Post, 112914533},
                   {:select, 1}]

    query = from(p in Post, where: p.id in ^[1, 2, 3])
    {_query, _params, key} = prepare(query)
    assert key == :nocache
  end

  test "prepare: subqueries" do
    {query, params, key} = prepare(from(subquery(Post), []))
    assert %{query: %Ecto.Query{}, params: []} = query.from
    assert params == []
    assert key == [:all, [:all, {"posts", Ecto.Query.PlannerTest.Post, 112914533}]]

    posts = from(p in Post, where: p.title == ^"hello")
    query = from(c in Comment, join: p in subquery(posts), on: c.post_id == p.id)
    {query, params, key} = prepare(query, [])
    assert {"comments", Ecto.Query.PlannerTest.Comment} = query.from
    assert [%{source: %{query: %Ecto.Query{}, params: ["hello"]}}] = query.joins
    assert params == ["hello"]
    assert [[], {:join, [{:inner, [:all|_], _}]}, {"comments", _, _}] = key
  end

  test "prepare: subqueries do not support association joins" do
    assert_raise Ecto.QueryError, ~r/an only perform association joins on sources with a schema in query/, fn ->
      prepare(from(p in subquery(Post), join: c in assoc(p, :comment)))
    end
  end

  test "prepare: subqueries do not support preloads" do
    query = from p in Post, join: c in assoc(p, :comments), preload: [comments: c]
    assert_raise Ecto.SubQueryError, ~r/cannot preload associations in subquery/, fn ->
      prepare(from(subquery(query), []))
    end
  end

  test "prepare: subqueries validates select fields" do
    query = prepare(from(subquery(Post), [])) |> elem(0)
    assert [{:id, 0}, {:title, 0} | _] = query.from.types

    query = from p in "posts", select: p.code
    query = prepare(from(subquery(query), [])) |> elem(0)
    assert [code: 0] = query.from.types

    query = from p in Post, select: p.code
    query = prepare(from(subquery(query), [])) |> elem(0)
    assert [code: 0] = query.from.types

    query = from p in Post, join: c in assoc(p, :comments), select: {p.code, c}
    query = prepare(from(subquery(query), [])) |> elem(0)
    assert [{:code, 0}, {:id, 1} | _] = query.from.types

    query = from p in Post, select: 1
    assert_raise Ecto.SubQueryError, ~r/subquery must select at least one source/, fn ->
      prepare(from(subquery(query), []))
    end

    query = from p in Post, select: fragment("? + ?", p.id, p.id)
    assert_raise Ecto.SubQueryError, ~r/subquery can only select sources/, fn ->
      prepare(from(subquery(query), []))
    end

    query = from p in Post, join: c in assoc(p, :comments), select: {p, c}
    assert_raise Ecto.SubQueryError, ~r/`id` is selected from two different sources in subquery/, fn ->
      prepare(from(subquery(query), []))
    end
  end

  test "prepare: allows type casting from subquery types" do
    query = subquery(from p in Post, join: c in assoc(p, :comments),
                                     select: {p.id, p.title, c.posted})

    datetime = %Ecto.DateTime{year: 2015, month: 1, day: 7, hour: 21, min: 18, sec: 13, usec: 0}
    {_query, params, _key} = prepare(query |> where([c], c.posted == ^datetime))
    assert params == [{{2015, 1, 7}, {21, 18, 13, 0}}]

    permalink = "1-hello-world"
    {_query, params, _key} = prepare(query |> where([p], p.id == ^permalink))
    assert params == [1]

    assert_raise Ecto.CastError, ~r/value `1` in `where` cannot be cast to type :string in query/, fn ->
      prepare(query |> where([p], p.title == ^1))
    end

    assert_raise Ecto.QueryError, ~r/field `unknown` does not exist in subquery in query/, fn ->
      prepare(query |> where([p], p.unknown == ^1))
    end
  end

  test "prepare: wraps subquery errors" do
    exception = assert_raise Ecto.SubQueryError, fn ->
      query = Post |> where([p], p.title == ^nil)
      prepare(from(subquery(query), []))
    end

    assert %Ecto.CastError{} = exception.exception
    assert Exception.message(exception) =~ "the following exception happened when compiling a subquery."
    assert Exception.message(exception) =~ "value `nil` in `where` cannot be cast to type :string"
    assert Exception.message(exception) =~ "where: p.title == ^nil"
    assert Exception.message(exception) =~ "from p in subquery(from p in Ecto.Query.PlannerTest.Post"
  end

  test "normalize: tagged types" do
    {query, params} = from(Post, []) |> select([p], type(^"1", :integer))
                                     |> normalize_with_params
    assert query.select.expr ==
           %Ecto.Query.Tagged{type: :integer, value: {:^, [], [0]}, tag: :integer}
    assert params == [1]

    {query, params} = from(Post, []) |> select([p], type(^"1", Custom.Permalink))
                                     |> normalize_with_params
    assert query.select.expr ==
           %Ecto.Query.Tagged{type: :id, value: {:^, [], [0]}, tag: Custom.Permalink}
    assert params == [1]

    {query, params} = from(Post, []) |> select([p], type(^"1", p.visits))
                                     |> normalize_with_params
    assert query.select.expr ==
           %Ecto.Query.Tagged{type: :integer, value: {:^, [], [0]}, tag: :integer}
    assert params == [1]

    assert_raise Ecto.CastError, ~r/value `"1"` in `select` cannot be cast to type Ecto.DateTime/, fn ->
      from(Post, []) |> select([p], type(^"1", Ecto.DateTime)) |> normalize
    end
  end

  test "normalize: dumps in query expressions" do
    assert_raise Ecto.QueryError, ~r"cannot dump value", fn ->
      normalize(from p in Post, where: p.posted == "2014-04-17 00:00:00")
    end
  end

  test "normalize: validate fields" do
    message = ~r"field `Ecto.Query.PlannerTest.Comment.temp` in `select` does not exist in the schema"
    assert_raise Ecto.QueryError, message, fn ->
      query = from(Comment, []) |> select([c], c.temp)
      normalize(query)
    end
  end

  test "normalize: validate fields in left side of in expressions" do
    query = from(Post, []) |> where([p], p.id in [1, 2, 3])
    normalize(query)

    message = ~r"cannot dump value `1` to type :string"
    assert_raise Ecto.QueryError, message, fn ->
      query = from(Comment, []) |> where([c], c.text in [1, 2, 3])
      normalize(query)
    end
  end

  test "normalize: flattens and expands right side of in expressions" do
    {query, params} = where(Post, [p], p.id in [1, 2, 3]) |> normalize_with_params()
    assert Macro.to_string(hd(query.wheres).expr) == "&0.id() in [1, 2, 3]"
    assert params == []

    {query, params} = where(Post, [p], p.id in [^1, 2, ^3]) |> normalize_with_params()
    assert Macro.to_string(hd(query.wheres).expr) == "&0.id() in [^0, 2, ^1]"
    assert params == [1, 3]

    {query, params} = where(Post, [p], p.id in ^[]) |> normalize_with_params()
    assert Macro.to_string(hd(query.wheres).expr) == "&0.id() in []"
    assert params == []

    {query, params} = where(Post, [p], p.id in ^[1, 2, 3]) |> normalize_with_params()
    assert Macro.to_string(hd(query.wheres).expr) == "&0.id() in ^(0, 3)"
    assert params == [1, 2, 3]

    {query, params} = where(Post, [p], p.title == ^"foo" and p.id in ^[1, 2, 3] and
                                       p.title == ^"bar") |> normalize_with_params()
    assert Macro.to_string(hd(query.wheres).expr) ==
           "&0.title() == ^0 and &0.id() in ^(1, 3) and &0.title() == ^4"
    assert params == ["foo", 1, 2, 3, "bar"]
  end

  test "normalize: reject empty order by and group by" do
    query = order_by(Post, [], []) |> normalize()
    assert query.order_bys == []

    query = order_by(Post, [], ^[]) |> normalize()
    assert query.order_bys == []

    query = group_by(Post, [], []) |> normalize()
    assert query.group_bys == []
  end

  test "normalize: select" do
    query = from(Post, []) |> normalize()
    assert query.select.expr == {:&, [], [0]}
    assert query.select.fields == [{:&, [], [0, [:id, :title, :text, :code, :posted, :visits, :links], 7]}]

    query = from(Post, []) |> select([p], {p, p.title}) |> normalize()
    assert query.select.fields ==
           [{:&, [], [0, [:id, :title, :text, :code, :posted, :visits, :links], 7]},
            {{:., [], [{:&, [], [0]}, :title]}, [ecto_type: :string], []}]

    query = from(Post, []) |> select([p], {p.title, p}) |> normalize()
    assert query.select.fields ==
           [{:&, [], [0, [:id, :title, :text, :code, :posted, :visits, :links], 7]},
            {{:., [], [{:&, [], [0]}, :title]}, [ecto_type: :string], []}]

    query =
      from(Post, [])
      |> join(:inner, [_], c in Comment)
      |> preload([_, c], comments: c)
      |> select([p, _], {p.title, p})
      |> normalize()
    assert query.select.fields ==
           [{:&, [], [0, [:id, :title, :text, :code, :posted, :visits, :links], 7]},
            {:&, [], [1, [:id, :text, :posted, :uuid, :post_id], 5]},
            {{:., [], [{:&, [], [0]}, :title]}, [ecto_type: :string], []}]
  end

  test "normalize: select with take" do
    query = from(Post, []) |> select([p], take(p, [:id, :title])) |> normalize()
    assert query.select.expr == {:&, [], [0]}
    assert query.select.fields == [{:&, [], [0, [:id, :title], 2]}]

    query = from(Post, []) |> select([p], {take(p, [:id, :title]), p.title}) |> normalize()
    assert query.select.fields ==
           [{:&, [], [0, [:id, :title], 2]},
            {{:., [], [{:&, [], [0]}, :title]}, [ecto_type: :string], []}]

    query =
      from(Post, [])
      |> join(:inner, [_], c in Comment)
      |> select([p, c], {p, take(c, [:id, :text])})
      |> normalize()
    assert query.select.fields ==
           [{:&, [], [0, [:id, :title, :text, :code, :posted, :visits, :links], 7]},
            {:&, [], [1, [:id, :text], 2]}]
  end

  test "normalize: preload" do
    message = ~r"the binding used in `from` must be selected in `select` when using `preload`"
    assert_raise Ecto.QueryError, message, fn ->
      Post |> preload(:hello) |> select([p], p.title) |> normalize
    end
  end

  test "normalize: preload assoc" do
    query = from(p in Post, join: c in assoc(p, :comments), preload: [comments: c])
    normalize(query)

    message = ~r"field `Ecto.Query.PlannerTest.Post.not_field` in preload is not an association"
    assert_raise Ecto.QueryError, message, fn ->
      query = from(p in Post, join: c in assoc(p, :comments), preload: [not_field: c])
      normalize(query)
    end

    message = ~r"requires an inner or left join, got right join"
    assert_raise Ecto.QueryError, message, fn ->
      query = from(p in Post, right_join: c in assoc(p, :comments), preload: [comments: c])
      normalize(query)
    end
  end

  test "normalize: all does not allow updates" do
    message = ~r"`all` does not allow `update` expressions"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, update: [set: [name: "foo"]]) |> normalize(:all)
    end
  end

  test "normalize: update all only allow filters and checks updates" do
    message = ~r"`update_all` requires at least one field to be updated"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, select: p, update: []) |> normalize(:update_all)
    end

    message = ~r"duplicate field `title` for `update_all`"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, select: p, update: [set: [title: "foo", title: "bar"]])
      |> normalize(:update_all)
    end

    message = ~r"`update_all` allows only `where` and `join` expressions in query"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, select: p, update: [set: [title: "foo"]]) |> normalize(:update_all)
    end
  end

  test "normalize: delete all only allow filters and forbids updates" do
    message = ~r"`delete_all` does not allow `update` expressions"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, update: [set: [name: "foo"]]) |> normalize(:delete_all)
    end

    message = ~r"`delete_all` allows only `where` and `join` expressions in query"
    assert_raise Ecto.QueryError, message, fn ->
      from(p in Post, select: p) |> normalize(:delete_all)
    end
  end

  test "normalize: subqueries" do
    assert_raise Ecto.SubQueryError, ~r/does not allow `update` expressions in query/, fn ->
      query = from p in Post, update: [set: [title: nil]]
      normalize(from(subquery(query), []))
    end

    assert_raise Ecto.QueryError, ~r/`update_all` does not allow subqueries in `from`/, fn ->
      query = from p in Post
      normalize(from(subquery(query), update: [set: [title: nil]]), :update_all)
    end
  end

  test "normalize: subqueries with params in from" do
    query = from p in Post,
              where: [title: ^"hello"],
              order_by: [asc: p.text == ^"world"]

    query = from p in subquery(query),
              where: p.text == ^"last",
              select: [p.title, ^"first"]

    {query, params} = normalize_with_params(query)
    assert [_, {:^, _, [0]}] = query.select.expr
    assert [%{expr: {:==, [], [_, {:^, [], [1]}]}}] = query.from.query.wheres
    assert [%{expr: [asc: {:==, [], [_, {:^, [], [2]}]}]}] = query.from.query.order_bys
    assert [%{expr: {:==, [], [_, {:^, [], [3]}]}}] = query.wheres
    assert params == ["first", "hello", "world", "last"]
  end

  test "normalize: subqueries with params in join" do
    query = from p in Post,
              where: [title: ^"hello"],
              order_by: [asc: p.text == ^"world"]

    query = from c in Comment,
              join: p in subquery(query),
              on: p.text == ^"last",
              select: [p.title, ^"first"]

    {query, params} = normalize_with_params(query)
    assert [_, {:^, _, [0]}] = query.select.expr
    assert [%{expr: {:==, [], [_, {:^, [], [1]}]}}] = hd(query.joins).source.query.wheres
    assert [%{expr: [asc: {:==, [], [_, {:^, [], [2]}]}]}] = hd(query.joins).source.query.order_bys
    assert {:==, [], [_, {:^, [], [3]}]} = hd(query.joins).on.expr
    assert params == ["first", "hello", "world", "last"]
  end

  test "normalize: merges subqueries fields when requested" do
    query = from p in Post, select: {p.id, p.title}
    query = normalize(from(subquery(query), []))
    assert query.select.fields == [{:&, [], [0, [:id, :title], 2]}]

    query = from p in Post, select: {p.id, p.title}
    query = normalize(from(p in subquery(query), select: p.title))
    assert query.select.fields == [{{:., [], [{:&, [], [0]}, :title]}, [ecto_type: :string], []}]

    query = from p in Post, select: {p.id, p.title}
    query = normalize(from(c in Comment, join: p in subquery(query), select: p))
    assert query.select.fields == [{:&, [], [1, [:id, :title], 2]}]

    query = from p in Post, select: {p.id, p.title}
    query = normalize(from(c in Comment, join: p in subquery(query), select: p.title))
    assert query.select.fields == [{{:., [], [{:&, [], [1]}, :title]}, [ecto_type: :string], []}]

    query = from p in Post, select: {p.id, p.title}
    assert_raise Ecto.QueryError, ~r/cannot take multiple fields on fragment or subquery sources in query/, fn ->
      normalize(from(p in subquery(query), select: [:title]))
    end
  end
end
