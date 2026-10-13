-module(kraft_test_trace_handler).
-export([init/2]).

-include_lib("opentelemetry_api/include/otel_tracer.hrl").

init(Req, {trace, State}) ->
    ?with_span(<<"handler.work">>, fun(_) -> init(Req, State) end);
init(Req, <<"options-retained">> = State) ->
    {ok, cowboy_req:reply(200, #{}, State, Req), State};
init(Conn, #{}) ->
    {respond, Conn, {json, #{result => ok}}}.
