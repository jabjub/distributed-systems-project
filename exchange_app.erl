-module(exchange_app).
-behaviour(application).

-export([start/0, start/2, stop/1, cluster_nodes/0]).

-record(subscriptions, {
    client_pid,
    stock,
    threshold
}).

start() ->
    application:start(exchange_app).

start(_StartType, _StartArgs) ->
    bootstrap(),
    exchange_sup:start_link().

stop(_State) ->
    ok.

bootstrap() ->
    ensure_schema_exists(),
    ensure_cluster_links(),
    ensure_mnesia_started(),
    ensure_session_table(),
    ensure_subscriptions_table(),
    ok.

ensure_cluster_links() ->
    Peers = [Node || Node <- cluster_nodes(), Node =/= node()],
    lists:foreach(fun(Node) -> net_kernel:connect_node(Node) end, Peers),
    ok.

cluster_nodes() ->
    lists:usort([node() | discovered_peers()]).

discovered_peers() ->
    case os:getenv("STOCK_CLUSTER_NODES") of
        false ->
            discover_from_world();
        "" ->
            discover_from_world();
        NodesStr ->
            parse_nodes(NodesStr)
    end.

discover_from_world() ->
    case net_adm:world() of
        {ok, Nodes} ->
            Nodes;
        {error, _} ->
            []
    end.

parse_nodes(NodesStr) ->
    Raw = string:tokens(NodesStr, ",; "),
    lists:filtermap(
      fun(Token) ->
          Clean = string:trim(Token),
          case Clean of
              "" -> false;
              _ ->
                  try
                      {true, list_to_atom(Clean)}
                  catch
                      _:_ -> false
                  end
          end
      end,
      Raw).

ensure_schema_exists() ->
    case mnesia:create_schema([node()]) of
        ok ->
            io:format("[mnesia] created local schema for ~p~n", [node()]),
            ok;
        {error, {_, {already_exists, _}}} ->
            ok;
        {error, {already_exists, _}} ->
            ok;
        {error, Reason} ->
            io:format("[mnesia] local schema check returned ~p~n", [Reason]),
            maybe_recreate_schema(Reason)
    end.

maybe_recreate_schema(_Reason) ->
    case os:getenv("STOCK_RECREATE_SCHEMA") of
        "1" ->
            io:format("[mnesia] recreating local schema for node ~p~n", [node()]),
            _ = mnesia:stop(),
            _ = mnesia:delete_schema([node()]),
            _ = mnesia:create_schema([node()]),
            ok;
        _ ->
            io:format("[mnesia] set STOCK_RECREATE_SCHEMA=1 to force local schema recreation for this node name~n", []),
            ok
    end.

ensure_mnesia_started() ->
    case mnesia:system_info(running_db_nodes) of
        [] ->
            ok = mnesia:start();
        _ ->
            ok
    end,
    _ = mnesia:change_config(extra_db_nodes, [Node || Node <- discovered_peers(), Node =/= node()]),
    ok = mnesia:wait_for_tables([schema], 10000),
    ok.

ensure_session_table() ->
    case ets:info(client_sessions) of
        undefined ->
            _ = ets:new(client_sessions, [named_table, public, set, {read_concurrency, true}, {write_concurrency, true}]),
            ok;
        _ ->
            ok
    end.

ensure_subscriptions_table() ->
    Attrs = record_info(fields, subscriptions),
    ConnectedCopies = [node() | [Node || Node <- discovered_peers(), Node =/= node(), lists:member(Node, nodes())]],
    TableOpts = [{attributes, Attrs}, {type, bag}, {disc_copies, ConnectedCopies}],
    case mnesia:create_table(subscriptions, TableOpts) of
        {atomic, ok} ->
            ok;
        {aborted, {already_exists, subscriptions}} ->
            ensure_table_copies();
        {aborted, {node_not_running, _}} ->
            ensure_table_copies();
        {aborted, Reason} ->
            case Reason of
                {already_exists, subscriptions} -> ensure_table_copies();
                _ ->
                    _ = mnesia:create_table(subscriptions, [{attributes, Attrs}, {type, bag}, {disc_copies, [node()]}]),
                    ensure_table_copies()
            end
    end,
    ensure_table_copies(),
    ok.

ensure_table_copies() ->
        TableNodes = [Node || Node <- discovered_peers(), lists:member(Node, nodes())],
    lists:foreach(
      fun(Node) ->
          case lists:member(Node, mnesia:table_info(subscriptions, disc_copies)) of
              true -> ok;
              false ->
                  _ = catch mnesia:add_table_copy(subscriptions, Node, disc_copies),
                  ok
          end
      end,
            TableNodes),
    ok.
