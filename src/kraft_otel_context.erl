-module(kraft_otel_context).
-behaviour(cowboy_stream).
-behaviour(cowboy_middleware).

-export([init/3, data/4, info/3, terminate/3, early_error/5]).
-export([execute/2]).

init(StreamID, Req, Opts) ->
    % Telemetry runs in the connection process; Cowboy passes Env to the handler.
    Env = maps:get(env, Opts, #{}),
    Context = otel_ctx:get_current(),
    try
        cowboy_stream:init(
            StreamID,
            Req,
            Opts#{env => Env#{kraft_otel_context => Context}}
        )
    after
        otel_ctx:clear()
    end.

execute(Req, #{kraft_otel_context := Context} = Env) ->
    otel_ctx:attach(Context),
    {ok, Req, maps:remove(kraft_otel_context, Env)}.

data(StreamID, IsFin, Data, State) ->
    cowboy_stream:data(StreamID, IsFin, Data, State).

info(StreamID, Info, State) ->
    cowboy_stream:info(StreamID, Info, State).

terminate(StreamID, Reason, State) ->
    cowboy_stream:terminate(StreamID, Reason, State).

early_error(StreamID, Reason, Req, Resp, Opts) ->
    cowboy_stream:early_error(StreamID, Reason, Req, Resp, Opts).
