%%%-------------------------------------------------------------------
%% @doc kraft public API
%% @end
%%%-------------------------------------------------------------------

-module(kraft_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    case application:get_env(kraft, opentelemetry, false) of
        false ->
            kraft_sup:start_link();
        Options when is_map(Options) ->
            {ok, _} = application:ensure_all_started(opentelemetry_cowboy),
            ok = opentelemetry_cowboy:setup(Options),
            {ok, Pid} = kraft_sup:start_link(),
            HandlerId = maps:get(handler_id, Options, otel_cowboy),
            {ok, Pid, {opentelemetry_cowboy, HandlerId}}
    end.

stop({opentelemetry_cowboy, _} = HandlerId) ->
    _ = telemetry:detach(HandlerId),
    ok;
stop(_State) ->
    ok.

%% internal functions
