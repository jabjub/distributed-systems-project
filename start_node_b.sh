#!/usr/bin/env bash
erl -name exchange_b@192.168.1.102 -setcookie stockcookie -mnesia schema_location ram -pa ebin -s exchange_app start
