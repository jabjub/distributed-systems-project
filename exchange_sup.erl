-module(exchange_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    PriceServer = #{id => price_server,
        start => {price_server, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [price_server]},
    TcpListener = #{id => tcp_listener,
        start => {tcp_listener, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [tcp_listener]},
    {ok, {{one_for_one, 5, 10}, [PriceServer, TcpListener]}}.
