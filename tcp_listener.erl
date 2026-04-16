-module(tcp_listener).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),

    Port = choose_port(node()),

    case gen_tcp:listen(Port, [binary, {packet, line}, {active, false}, {reuseaddr, true}]) of
        {ok, ListenSocket} ->
            io:format("~n[listener] ~p listening on port ~p~n", [node(), Port]),
            Acceptor = spawn_link(fun() -> accept_loop(ListenSocket) end),
            {ok, #{listen_socket => ListenSocket, acceptor => Acceptor}};
        {error, Reason} ->
            io:format("~n[listener] failed on ~p:~p reason=~p~n", [node(), Port, Reason]),
            {stop, Reason}
    end.

choose_port(NodeAtom) ->
    NodeStr = atom_to_list(NodeAtom),
    case string:tokens(NodeStr, "@") of
        [Name, Host] ->
            case {Name, is_local_host(Host)} of
                {"exchange_b", true} -> 9001;
                _ -> 9000
            end;
        _ ->
            9000
    end.

is_local_host("127.0.0.1") -> true;
is_local_host("localhost") -> true;
is_local_host("::1") -> true;
is_local_host(_Host) -> false.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', _Pid, Reason}, State) ->
    {stop, Reason, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    case maps:get(listen_socket, State, undefined) of
        undefined -> ok;
        ListenSocket -> gen_tcp:close(ListenSocket)
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

accept_loop(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            HandlerPid = spawn(fun() -> client_handler:start(Socket) end),
            ok = gen_tcp:controlling_process(Socket, HandlerPid),
            HandlerPid ! socket_ready,
            accept_loop(ListenSocket);
        {error, closed} ->
            ok;
        {error, _Reason} ->
            accept_loop(ListenSocket)
    end.