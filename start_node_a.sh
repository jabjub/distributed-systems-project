#!/usr/bin/env bash
erl -name exchange_a@192.168.1.101 -setcookie stockcookie -mnesia schema_location ram -pa ebin -s exchange_app start
