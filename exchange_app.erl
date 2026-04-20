-module(exchange_app).
-behaviour(application).

-export([start/0, start/2, stop/1, cluster_nodes/0]).

-define(DEFAULT_CLUSTER_NODES, "nodeA@10.2.1.3,nodeB@10.2.1.14").

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

  %% 1. Force RAM-only schema location so Mnesia stays memory-backed.
  _ = mnesia:stop(),
  ok = application:set_env(mnesia, schema_location, ram),
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
    false -> parse_nodes(?DEFAULT_CLUSTER_NODES);
    "" -> parse_nodes(?DEFAULT_CLUSTER_NODES);
    NodesStr -> parse_nodes(NodesStr)
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
  Nodes = target_cluster_nodes(),

  %% Create table in RAM across active-active nodes.
  CreateRes = mnesia:create_table(subscriptions, [
    {attributes, Attrs},
    {type, bag},
    {ram_copies, Nodes}
  ]),
  _ = normalize_create_result(CreateRes),

  %% Ensure all configured nodes eventually have RAM copies.
  lists:foreach(
    fun(TargetNode) ->
      _ = catch mnesia:add_table_copy(subscriptions, TargetNode, ram_copies),
      ok
    end,
    Nodes
  ),

  %% Wait to ensure the table is ready before the app finishes booting
  _ = mnesia:wait_for_tables([subscriptions], 5000),
  ok.

target_cluster_nodes() ->
  Configured = [N || N <- discovered_peers(), node_is_alive(N)],
  lists:usort([node() | Configured]).

node_is_alive(NodeName) when NodeName =:= node() ->
  true;
node_is_alive(NodeName) ->
  case net_adm:ping(NodeName) of
    pong -> true;
    pang -> false
  end.

normalize_create_result({atomic, ok}) -> ok;
normalize_create_result({aborted, {already_exists, subscriptions}}) -> ok;
normalize_create_result({aborted, Reason}) ->
  io:format("[exchange_app] subscriptions table create returned: ~p~n", [Reason]),
  ok.
