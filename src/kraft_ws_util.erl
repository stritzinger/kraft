-module(kraft_ws_util).

-include_lib("kernel/include/logger.hrl").

% API
-export([setup/4]).
-export([callbacks/2]).
-export([handshake/2]).
-export([call/3]).
-export([raw_call/3]).

% Callbacks
-behaviour(cowboy_websocket).
-export([init/2]).
-export([websocket_init/1]).
-export([websocket_handle/2]).
-export([websocket_info/2]).
-export([terminate/3]).

%--- API -----------------------------------------------------------------------

setup(UserOpts, App, Handler, MState) ->
    Opts = maps:merge(default_opts(), UserOpts),
    {
        ?MODULE,
        #{
            opts => Opts,
            app => App,
            module => callback_module(Opts),
            handler => Handler,
            state => MState
        }
    }.

callbacks(Callbacks, #{handler := Handler} = State0) ->
    CheckCallback = fun(C, Cs) ->
        maps:put(C, lists:member(C, Handler:module_info(exports)), Cs)
    end,
    Exported = lists:foldl(CheckCallback, #{}, Callbacks),
    State0#{callbacks => Exported}.

handshake(Req, #{callbacks := #{{handshake, 3} := false}} = State0) ->
    {cowboy_websocket, Req, State0};
handshake(Req, #{handler := Handler, state := MState0} = State0) ->
    Conn0 = kraft_conn:new(Req, State0),
    {Params, _Conn1} = kraft_conn:params(Conn0),
    case Handler:handshake({Req, MState0}, Params, MState0) of
        {reply, Code, Headers, Body} ->
            Resp = cowboy_req:reply(Code, Headers, Body, Req),
            {ok, Resp, State0};
        {ok, MState1} ->
            {cowboy_websocket, Req, State0#{state => MState1}};
        {ok, Headers, MState1} ->
            Req1 = cowboy_req:set_resp_headers(Headers, Req),
            {cowboy_websocket, Req1, State0#{state => MState1}}
    end.

call(info, _Args, #{callbacks := #{{info, 2} := false}} = State0) ->
    {[], State0};
call(terminate, _Args, #{callbacks := #{{terminate, 2} := false}} = State0) ->
    {[], State0};
call(Func, Args, State0) ->
    {Commands, MState1} = raw_call(Func, Args, State0),
    {Commands, State0#{state => MState1}}.

raw_call(terminate, _Args, #{callbacks := #{{terminate, 2} := false}}) ->
    ok;
raw_call(Func, Args, #{handler := Handler, state := MState0}) ->
    erlang:apply(Handler, Func, Args ++ [MState0]).

%--- Callbacks -----------------------------------------------------------------

init(Req, State0) ->
    State1 = kraft_ws_util:callbacks(
        [{handshake, 3}, {info, 2}, {terminate, 2}],
        State0
    ),
    Conn = kraft_conn:new(Req, State0),
    kraft_ws_util:handshake(Req, State1#{conn => Conn}).

websocket_init(#{conn := Conn} = State0) ->
    State1 = trigger_ping(State0),
    module(init, [Conn], State1).

websocket_handle({text, _} = Frame, State0) ->
    module(handle, [Frame], State0);
websocket_handle(Pong, State0) when
    Pong =:= pong; element(1, Pong) =:= pong
->
    State1 = cancel_pong_timeout(State0),
    {[], State1};
websocket_handle(Ping, State0) when
    Ping =:= ping; element(1, Ping) =:= ping
->
    {[], State0};
websocket_handle(Frame, State0) ->
    ?LOG_WARNING("Websocket unhandled frame: ~p", [Frame]),
    {[], State0}.

websocket_info('$kraft_ws_ping', State0) ->
    State1 = trigger_pong_timeout(trigger_ping(State0)),
    {[ping], State1};
websocket_info('$kraft_ws_pong_timeout', State0) ->
    {[{close, 1011, <<"timeout waiting for pong">>}], State0};
websocket_info(Info, State0) ->
    module(info, [Info], State0).

terminate(Reason, Req, State0) ->
    cancel_ping(State0),
    cancel_pong_timeout(State0),
    module(terminate, [Reason, Req], State0),
    ok.

%--- Internal ------------------------------------------------------------------

default_opts() -> #{type => raw,
                    ping => #{interval => 30_000},
                    pong => #{timeout => 1_000}}.

callback_module(#{type := raw}) -> kraft_ws;
callback_module(#{type := json}) -> kraft_ws_json;
callback_module(#{type := json_rpc}) -> kraft_ws_jsonrpc;
callback_module(#{type := Other}) -> error({invalid_kraft_ws_type, Other}).

trigger_ping(#{opts := #{ping := disabled}} = State0) ->
    State0;
trigger_ping(#{ping := #{target := Last}} = State0) ->
    #{opts := #{ping := #{interval := Interval}}} = State0,
    Target = Last + Interval,
    Ref = erlang:send_after(Target, self(), '$kraft_ws_ping', [{abs, true}]),
    mapz:deep_merge(State0, #{ping => #{timer => Ref, target => Target}});
trigger_ping(State0) ->
    trigger_ping(State0#{
        ping => #{target => erlang:monotonic_time(millisecond)}
    }).

trigger_pong_timeout(#{opts := #{ping := disabled}} = State0) ->
    State0;
trigger_pong_timeout(#{opts := #{pong := #{timeout := infinity}}} = State0) ->
    State0;
trigger_pong_timeout(#{pong := #{timer := Ref}} = State0) when
    Ref =/= undefined
->
    % do not start a second timeout
    State0;
trigger_pong_timeout(State0) ->
    #{opts := #{pong := #{timeout := Timeout}}} = State0,
    Ref = erlang:send_after(Timeout, self(), '$kraft_ws_pong_timeout'),
    mapz:deep_merge(State0, #{pong => #{timer => Ref}}).

cancel_ping(#{ping := #{timer := Ref} = Ping} = State0) ->
    erlang:cancel_timer(Ref, [{info, false}]),
    State0#{ping => Ping#{timer => undefined}};
cancel_ping(State0) ->
    State0.

cancel_pong_timeout(#{pong := #{timer := Ref} = Pong} = State0) when
    Ref =/= undefined
->
    erlang:cancel_timer(Ref, [{info, false}]),
    State0#{pong => Pong#{timer := undefined}};
cancel_pong_timeout(State0) ->
    State0.

module(Func, Args, #{module := Module} = State0) ->
    erlang:apply(Module, Func, Args ++ [State0]).
