@echo off
title Node B - VirtualTrade Exchange
echo Starting Node B...

set STOCK_CLUSTER_NODES=exchange_a@127.0.0.1,exchange_b@127.0.0.1
erl -name exchange_b@127.0.0.1 -setcookie stockcookie -pa ebin -eval "mnesia:start(), application:ensure_all_started(exchange_app)."