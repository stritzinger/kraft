-module(index).

-behaviour(application).

% Callbacks
-export([start/2]).
-export([stop/1]).

%--- Callbacks -----------------------------------------------------------------

start(_StartType, _StartArgs) ->
    kraft:start(#{port => 8090}, [{"/", kraft_static, #{}}]),
    {ok, self()}.

stop(_State) ->
    ok.
