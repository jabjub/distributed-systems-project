-module(price_server).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(DEFAULT_CLUSTER_NODES, "nodeA@10.2.1.3,nodeB@10.2.1.14").
-record(subscriptions, {
    client_pid,
    stock,
    threshold,
    raw_sub
}).

-record(state, {
    prices = #{<<"AAPL">> => 150.0, <<"TSLA">> => 200.0, <<"MSFT">> => 300.0},
    active = false,
    tick_ref = undefined
}).

-define(TICK_MS, 2000).
-define(DEFAULT_PRICES, #{<<"AAPL">> => 150.0, <<"TSLA">> => 200.0, <<"MSFT">> => 300.0}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
  _ = monitor_all_nodes(),
  _ = seed_rand(),

  _ = mnesia:wait_for_tables([subscriptions], 5000),

  InitialPrices = fetch_existing_prices(),
  {ok, maybe_activate(#state{prices = InitialPrices})}.

monitor_all_nodes() ->
  case catch net_kernel:monitor_nodes(true, [{node_type, all}, nodedown_reason]) of
    {'EXIT', _} ->
      net_kernel:monitor_nodes(true);
    _ ->
      ok
  end.

fetch_existing_prices() ->
  case gen_server:multi_call(cluster_peer_nodes(), ?MODULE, get_prices, 2000) of
    {[{_Node, ActivePrices} | _], _BadNodes} ->
      ActivePrices;
    _ ->
      ?DEFAULT_PRICES
  end.

handle_call(get_prices, _From, State = #state{prices = Prices}) ->
  {reply, Prices, State};
handle_call(_Request, _From, State) ->
  {reply, ok, State}.

handle_cast({sync_prices, SyncedPrices}, State = #state{active = false}) ->
  {noreply, State#state{prices = SyncedPrices}};
handle_cast(_Msg, State) ->
  {noreply, State}.

handle_info({nodeup, _Node}, State) ->
    {noreply, maybe_activate(State)};
handle_info({nodeup, _Node, _Info}, State) ->
    {noreply, maybe_activate(State)};
handle_info({nodedown, DeadNode}, State) ->
    cleanup_dead_node(DeadNode),
    {noreply, maybe_activate(State)};
handle_info({nodedown, DeadNode, _Info}, State) ->
    cleanup_dead_node(DeadNode),
    {noreply, maybe_activate(State)};
handle_info({subscribe, ClientPid, Stock, Threshold, RawSub}, State) ->
    {noreply, maybe_activate(handle_subscribe(ClientPid, Stock, Threshold, RawSub, State))};
handle_info({command, _ClientPid, _Raw}, State) ->
    {noreply, State};
handle_info(tick, State = #state{active = true}) ->
    UpdatedState = fluctuate_prices(State),
    {noreply, maybe_activate(schedule_tick(UpdatedState))};
handle_info(tick, State) ->
    {noreply, maybe_activate(State)};
handle_info(_Info, State) ->
    {noreply, State}.
    
cleanup_dead_node(DeadNode) ->
    Pattern = #subscriptions{client_pid = '_', stock = '_', threshold = '_', raw_sub = '_'},
    Subs = mnesia:dirty_match_object(subscriptions, Pattern),
    lists:foreach(
        fun(Sub) ->
            case node(Sub#subscriptions.client_pid) of
                DeadNode -> mnesia:dirty_delete_object(Sub);
                _ -> ok
            end
        end,
        Subs).

handle_subscribe(ClientPid, Stock, Threshold, RawSub, State)
    when is_pid(ClientPid), is_binary(Stock), is_float(Threshold), is_binary(RawSub) ->
    delete_raw_subscription(RawSub),
    Sub = #subscriptions{
        client_pid = ClientPid,
        stock = Stock,
        threshold = Threshold,
        raw_sub = RawSub
    },
    _ = mnesia:dirty_write(Sub),
    State;
handle_subscribe(_ClientPid, _Stock, _Threshold, _RawSub, State) ->
    State.

delete_raw_subscription(RawSub) ->
    Pattern = #subscriptions{client_pid = '_', stock = '_', threshold = '_', raw_sub = RawSub},
    Subs = mnesia:dirty_match_object(subscriptions, Pattern),
    lists:foreach(fun(Rec) -> mnesia:dirty_delete_object(Rec) end, Subs).

terminate(_Reason, State) ->
    cancel_tick(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

maybe_activate(State = #state{active = Active}) ->
    Leader = node() =:= leader_node(),
    case {Leader, Active} of
        {true, false} ->
            schedule_tick(State#state{active = true});
        {false, true} ->
            cancel_tick(State#state{active = false});
        _ ->
            State
    end.

leader_node() ->
    UpNodes = cluster_nodes(),
    lists:min(UpNodes).

cluster_nodes() ->
    lists:usort([N || N <- configured_cluster_nodes(), node_is_alive(N)]).

cluster_peer_nodes() ->
    [N || N <- cluster_nodes(), N =/= node()].

configured_cluster_nodes() ->
    case os:getenv("STOCK_CLUSTER_NODES") of
        false ->
            ParsedDefault = parse_cluster_nodes(?DEFAULT_CLUSTER_NODES),
            lists:usort([node() | ParsedDefault]);
        "" ->
            ParsedDefault = parse_cluster_nodes(?DEFAULT_CLUSTER_NODES),
            lists:usort([node() | ParsedDefault]);
        NodesStr ->
            Parsed = parse_cluster_nodes(NodesStr),
            lists:usort([node() | Parsed])
    end.

parse_cluster_nodes(NodesStr) ->
    RawNodes = string:tokens(NodesStr, ",; "),
    lists:filtermap(
      fun(Token) ->
          Clean = string:trim(Token),
          case Clean of
              "" ->
                  false;
              _ ->
                  try {true, list_to_atom(Clean)} catch _:_ -> false end
          end
      end,
      RawNodes).

node_is_alive(NodeName) when NodeName =:= node() ->
    true;
node_is_alive(NodeName) ->
    case net_adm:ping(NodeName) of
        pong -> true;
        pang -> false
    end.

schedule_tick(State = #state{tick_ref = undefined}) ->
    Ref = erlang:send_after(?TICK_MS, self(), tick),
    State#state{tick_ref = Ref};
schedule_tick(State) ->
    cancel_tick(State),
    schedule_tick(State#state{tick_ref = undefined}).

cancel_tick(State = #state{tick_ref = undefined}) ->
    State;
cancel_tick(State = #state{tick_ref = Ref}) ->
    _ = erlang:cancel_timer(Ref),
    State#state{tick_ref = undefined}.

fluctuate_prices(State = #state{prices = Prices}) ->
    NewPrices = maps:fold(
        fun(Stock, OldPrice, Acc) ->
            Delta = random_delta(),
            NewPrice = round_price(OldPrice * (1.0 + Delta)),
            io:format("[TICKER] ~s shifted to ~s~n", [Stock, format_price(NewPrice)]),

            deliver_alerts(Stock, OldPrice, NewPrice),

            maps:put(Stock, NewPrice, Acc)
        end,
        #{},
        Prices),
    
    gen_server:abcast(cluster_peer_nodes(), ?MODULE, {sync_prices, NewPrices}),
    
    State#state{prices = NewPrices}.

deliver_alerts(Stock, OldPrice, NewPrice) ->
    Pattern = #subscriptions{client_pid = '_', stock = Stock, threshold = '_', raw_sub = '_'},
    Subs = mnesia:dirty_match_object(subscriptions, Pattern),
    lists:foreach(
        fun(#subscriptions{client_pid = ClientPid, threshold = Threshold, raw_sub = RawSub} = Record) ->
            CrossedUp = (OldPrice < Threshold) andalso (NewPrice >= Threshold),
            CrossedDown = (OldPrice > Threshold) andalso (NewPrice =< Threshold),
            case CrossedUp orelse CrossedDown of
                true ->
                    send_alert(ClientPid, Stock, NewPrice, RawSub),
                    mnesia:dirty_delete_object(Record);
                false ->
                    ok
            end
        end,
        Subs),
    ok.

send_alert(ClientPid, Stock, Price, RawSub) ->
  ClientPid ! {alert, Stock, Price, RawSub}.

random_delta() ->
    Base = rand:uniform() - 0.5,
    Base * 0.01.

round_price(Value) ->
    erlang:round(Value * 100.0) / 100.0.

format_price(Price) ->
    lists:flatten(io_lib:format("~.2f", [Price])).

seed_rand() ->
    Seed = {erlang:unique_integer([positive]), erlang:phash2(erlang:monotonic_time()) + 1, erlang:phash2(node()) + 1},
    _ = rand:seed(exsplus, Seed),
    ok.
