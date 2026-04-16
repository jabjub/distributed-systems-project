-module(price_server).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(subscriptions, {
    client_pid,
    stock,
    threshold
}).

-record(state, {
    prices = #{<<"AAPL">> => 150.0, <<"TSLA">> => 200.0, <<"MSFT">> => 300.0},
    active = false,
    tick_ref = undefined
}).

-define(TICK_MS, 2000).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    _ = net_kernel:monitor_nodes(true),
    _ = seed_rand(),
    {ok, maybe_activate(#state{})}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({nodeup, _Node}, State) ->
    {noreply, maybe_activate(State)};
handle_info({nodedown, _Node}, State) ->
    {noreply, maybe_activate(State)};
handle_info(tick, State = #state{active = true}) ->
    UpdatedState = fluctuate_prices(State),
    {noreply, schedule_tick(UpdatedState)};
handle_info(tick, State) ->
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

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
    UpNodes = lists:usort([node() | nodes()]),
    lists:min(UpNodes).

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
        fun(Stock, Price, Acc) ->
            Delta = random_delta(),
            NewPrice = round_price(Price * (1.0 + Delta)),
            io:format("[TICKER] ~s shifted to ~s~n", [Stock, format_price(NewPrice)]),
            deliver_alerts(Stock, NewPrice),
            maps:put(Stock, NewPrice, Acc)
        end,
        #{},
        Prices),
    State#state{prices = NewPrices}.

deliver_alerts(Stock, NewPrice) ->
    Pattern = #subscriptions{client_pid = '_', stock = Stock, threshold = '_'},
    Subs = mnesia:dirty_match_object(subscriptions, Pattern),
    lists:foreach(
      %% 1. We added "= Record" here to capture the whole database entry
      fun(#subscriptions{client_pid = ClientPid, threshold = Threshold} = Record) ->
          case NewPrice >= Threshold of
              true ->
                  send_alert(ClientPid, Stock, NewPrice),
                  %% 2. THE KILL SWITCH: Delete the rule the exact millisecond it fires
                  mnesia:dirty_delete_object(Record);
              false ->
                  ok
          end
      end,
      Subs),
    ok.

send_alert(ClientPid, Stock, Price) ->
    case is_process_alive(ClientPid) of
        true ->
            case ets:lookup(client_sessions, ClientPid) of
                [{ClientPid, Socket}] ->
                    Message = ["ALERT ", binary_to_list(Stock), " HIT ", format_price(Price), "\n"],
                    _ = gen_tcp:send(Socket, Message),
                    ok;
                [] ->
                    ok
            end;
        false ->
            ok
    end.

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
