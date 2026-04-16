{application, exchange_app,
 [{description, "Distributed Stock Exchange"},
  {vsn, "1.0.0"},
  {modules, [exchange_app, exchange_sup, tcp_listener, client_handler, price_server]},
  {registered, [exchange_sup, price_server]},
  {applications, [kernel, stdlib, mnesia]},
  {mod, {exchange_app, []}},
  {env, []}
 ]}.