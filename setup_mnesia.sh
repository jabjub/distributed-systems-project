#!/usr/bin/env bash
set -euo pipefail

NODE_A_IP="${NODE_A_IP:-10.2.1.3}"
NODE_B_IP="${NODE_B_IP:-10.2.1.14}"
ERLANG_COOKIE="${ERLANG_COOKIE:-exchange_cookie}"
export STOCK_CLUSTER_NODES="${STOCK_CLUSTER_NODES:-nodeA@${NODE_A_IP},nodeB@${NODE_B_IP}}"

erl -noshell -name "setup_mnesia@${NODE_A_IP}" -setcookie "${ERLANG_COOKIE}" -eval "
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
	false -> [list_to_atom(\"nodeA@10.2.1.3\"), list_to_atom(\"nodeB@10.2.1.14\")];
	\"\" -> [list_to_atom(\"nodeA@10.2.1.3\"), list_to_atom(\"nodeB@10.2.1.14\")];
	S -> [node() | Parse(S)]
end,
Nodes = lists:usort(Nodes0),
io:format(\"[setup_mnesia] creating schema on nodes: ~p~n\", [Nodes]),
Res = mnesia:create_schema(Nodes),
io:format(\"[setup_mnesia] result: ~p~n\", [Res]),
init:stop()."
