#!/usr/bin/env bash
erl -noshell -name setup_mnesia@127.0.0.1 -setcookie stockcookie -eval "
Parse = fun(Str) ->
	Tokens = string:tokens(Str, \",; \"),
	lists:filtermap(fun(T) ->
		C = string:trim(T),
		case C of
			\"\" -> false;
			_ ->
				try {true, list_to_atom(C)}
				catch _:_ -> false end
		end
	end, Tokens)
end,
Nodes0 = case os:getenv(\"STOCK_CLUSTER_NODES\") of
	false ->
		case net_adm:world() of
			{ok, Ns} -> [node() | Ns];
			_ -> [node()]
		end;
	\"\" ->
		case net_adm:world() of
			{ok, Ns} -> [node() | Ns];
			_ -> [node()]
		end;
	S -> [node() | Parse(S)]
end,
Nodes = lists:usort(Nodes0),
io:format(\"[setup_mnesia] creating schema on nodes: ~p~n\", [Nodes]),
Res = mnesia:create_schema(Nodes),
io:format(\"[setup_mnesia] result: ~p~n\", [Res]),
init:stop()."
