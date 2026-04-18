-module(exchange_app).
-behaviour(application).

-export([start/0, start/2, stop/1, cluster_nodes/0]).

-record(subscriptions, {
  client_pid,
  stock,
  threshold,
  raw_sub
}).

start() ->
  application:start(exchange_app).

start(_StartType, _StartArgs) ->
  bootstrap(),
  exchange_sup:start_link().

stop(_State) ->
  ok.

bootstrap() ->
  ensure_cluster_links(),

  %% 1. Force RAM-only mode by deleting any old ghost disk schemas on boot
  _ = mnesia:stop(),
  _ = mnesia:delete_schema([node()]),
  ok = mnesia:start(),

  %% 2. Network Mnesia with the active cluster dynamically in RAM
  _ = mnesia:change_config(extra_db_nodes, nodes()),

  %% 3. Setup Tables
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
    false -> discover_from_world();
    "" -> discover_from_world();
    NodesStr -> parse_nodes(NodesStr)
  end.

discover_from_world() ->
  case net_adm:world() of
    {ok, Nodes} -> Nodes;
    {error, _} -> []
  end.

parse_nodes(NodesStr) ->
  Raw = string:tokens(NodesStr, ",; "),
  lists:filtermap(
    fun(Token) ->
      Clean = string:trim(Token),
      case Clean of
        "" -> false;
        _ ->
          try {true, list_to_atom(Clean)} catch _:_ -> false end
      end
    end, Raw).

ensure_session_table() ->
  case ets:info(client_sessions) of
    undefined ->
      _ = ets:new(client_sessions, [named_table, public, set, {read_concurrency, true}, {write_concurrency, true}]),
      ok;
    _ -> ok
  end.

ensure_subscriptions_table() ->
  Attrs = record_info(fields, subscriptions),
  Nodes = [node() | nodes()],

  %% Create table entirely in RAM across all connected nodes
  _ = mnesia:create_table(subscriptions, [
    {attributes, Attrs},
    {type, bag},
    {ram_copies, Nodes}
  ]),

  %% If Node A already made the table, ensure Node B grabs a RAM copy when it joins
  _ = catch mnesia:add_table_copy(subscriptions, node(), ram_copies),

  %% Wait to ensure the table is ready before the app finishes booting
  _ = mnesia:wait_for_tables([subscriptions], 5000),
  ok.