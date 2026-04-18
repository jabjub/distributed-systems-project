-module(client_handler).
-export([start/1]).

%% RENAME TO MATCH TABLE NAME: subscriptions
-record(subscriptions, {
    client_pid,
    stock,
    threshold,
    raw_sub
}).

start(Socket) ->
    receive
        socket_ready ->
            ClientPid = self(),
            ensure_session_table(),
            ets:insert(client_sessions, {ClientPid, Socket}),
            loop(Socket, ClientPid)
    after 5000 ->
        gen_tcp:close(Socket),
        exit(timeout_waiting_for_socket)
    end.

loop(Socket, ClientPid) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            handle_message(Socket, ClientPid, Data),
            loop(Socket, ClientPid);
        {error, closed} ->
            cleanup_client(ClientPid),
            exit(normal);
        {error, _Reason} ->
            cleanup_client(ClientPid),
            exit(socket_error)
    end.

handle_message(Socket, ClientPid, Data) ->
    CommandLine = string:trim(binary_to_list(Data)),
    Tokens = string:tokens(CommandLine, " \t\r\n"),
    case Tokens of
        ["SUB", StockStr, PriceStr] ->
            case parse_threshold(PriceStr) of
                {ok, Threshold} ->
                    RawSub = list_to_binary(CommandLine), %% Capture the raw string
                    Sub = #subscriptions{
                        client_pid = ClientPid, 
                        stock = list_to_binary(StockStr), 
                        threshold = Threshold, 
                        raw_sub = RawSub  %% Save it to Mnesia
                    },
                    _ = mnesia:dirty_write(Sub),
                    ok = gen_tcp:send(Socket, ["ACK ", CommandLine, "\n"]);
                {error, _} ->
                    ok = gen_tcp:send(Socket, "ERR UNKNOWN\n")
            end;
        ["PING"] ->
            ok = gen_tcp:send(Socket, "PONG\n");
        _ ->
            ok = gen_tcp:send(Socket, "ERR UNKNOWN\n")
    end.

parse_threshold(Value) ->
    %% SWAPPED CLAUSES: Catch the error atom specifically first
    case string:to_float(Value) of
        {error, no_float} ->
            try 
                {ok, float(list_to_integer(Value))}
            catch
                _:_:_ -> {error, invalid_threshold}
            end;
        {Float, _Rest} ->
            {ok, Float}
    end.

cleanup_client(ClientPid) ->
    ensure_session_table(),
    _ = ets:delete(client_sessions, ClientPid),
    %% TABLE NAME IS CORRECT HERE
    case mnesia:dirty_read(subscriptions, ClientPid) of
        [] -> ok;
        Records ->
            lists:foreach(fun(Rec) -> _ = mnesia:dirty_delete_object(Rec) end, Records)
    end,
    ok.

ensure_session_table() ->
    case ets:info(client_sessions) of
        undefined ->
            _ = ets:new(client_sessions, [named_table, public, set]),
            ok;
        _ ->
            ok
    end.