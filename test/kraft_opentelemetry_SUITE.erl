-module(kraft_opentelemetry_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("opentelemetry/include/otel_span.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_testcase/2, end_per_testcase/2]).
-export([
    disabled_by_default/1,
    disabled_explicitly/1,
    enabled/1,
    context_bridge/1,
    unsampled_parent/1,
    remote_parent/1,
    public_endpoint/1,
    restart/1
]).

-define(TABLE, kraft_test_spans).
-define(HANDLERS, [kraft_fallback_h, cowboy_compress_h, cowboy_stream_h]).

all() ->
    [
        disabled_by_default,
        disabled_explicitly,
        enabled,
        context_bridge,
        unsampled_parent,
        remote_parent,
        public_endpoint,
        restart
    ].

init_per_suite(Config) ->
    application:load(opentelemetry_cowboy),
    Parent = self(),
    Owner = spawn(fun() ->
        ets:new(?TABLE, [named_table, public, set, {keypos, #span.span_id}]),
        Parent ! ready,
        receive
            stop -> ok
        end
    end),
    receive
        ready -> ok
    end,
    application:set_env(
        opentelemetry, traces_exporter, {kraft_test_trace_exporter, ?TABLE}
    ),
    application:set_env(
        opentelemetry, sampler, {parent_based, #{root => always_on}}
    ),
    application:set_env(opentelemetry, text_map_propagators, [trace_context]),
    application:set_env(opentelemetry, span_processor, batch),
    application:set_env(opentelemetry, bsp_scheduled_delay_ms, 10),
    {ok, Apps1} = application:ensure_all_started(opentelemetry),
    {ok, Apps2} = application:ensure_all_started(telemetry),
    {ok, Apps3} = application:ensure_all_started(gun),
    [{owner, Owner}, {apps, lists:reverse(Apps1 ++ Apps2 ++ Apps3)} | Config].

end_per_suite(Config) ->
    application:stop(opentelemetry_cowboy),
    application:stop(opentelemetry_telemetry),
    [application:stop(App) || App <- ?config(apps, Config)],
    ?config(owner, Config) ! stop,
    ok.

init_per_testcase(_Case, Config) ->
    application:unset_env(kraft, opentelemetry),
    ets:delete_all_objects(?TABLE),
    Config.

end_per_testcase(_Case, _Config) ->
    application:stop(kraft),
    application:unset_env(kraft, opentelemetry),
    ?assertEqual([], telemetry:list_handlers([cowboy, request, start])),
    ok.

disabled_by_default(Config) ->
    with_listener(Config, fun(Port, Options) ->
        ?assertEqual(?HANDLERS, maps:get(stream_handlers, Options)),
        ?assertNot(maps:is_key(middlewares, Options)),
        ?assertEqual([], telemetry:list_handlers([cowboy, request, start])),
        {200, <<"options-retained">>} = request(Port, "/devices/42", []),
        timer:sleep(50),
        ?assertEqual([], ets:tab2list(?TABLE))
    end).

disabled_explicitly(Config) ->
    application:set_env(kraft, opentelemetry, false),
    disabled_by_default(Config).

enabled(Config) ->
    application:set_env(kraft, opentelemetry, #{}),
    with_listener(Config, fun(Port, Options) ->
        ?assertEqual(
            [cowboy_telemetry_h, kraft_otel_context | ?HANDLERS],
            maps:get(stream_handlers, Options)
        ),
        ?assertEqual(
            [kraft_otel_context, cowboy_router, cowboy_handler],
            maps:get(middlewares, Options)
        ),
        {200, <<"options-retained">>} = request(
            Port, "/devices/42?q=sample", []
        ),
        Root1 = wait_span(),
        Attrs1 = assert_http(Root1, <<"/devices/42">>, 200),
        ?assertEqual(<<"q=sample">>, maps:get('url.query', Attrs1)),
        ets:delete_all_objects(?TABLE),
        {200, Body} = request(Port, "/controller/42", []),
        ?assertEqual(
            #{<<"result">> => <<"ok">>}, json:decode(Body)
        ),
        assert_http(wait_span(), <<"/controller/42">>, 200),
        ets:delete_all_objects(?TABLE),
        {200, Html} = request(Port, "/static", []),
        ?assertNotEqual(nomatch, binary:match(Html, <<"<html">>)),
        assert_http(wait_span(), <<"/static">>, 200),
        ets:delete_all_objects(?TABLE),
        {404, _} = request(Port, "/unknown", []),
        assert_http(wait_span(), <<"/unknown">>, 404)
    end).

context_bridge(Config) ->
    application:set_env(kraft, opentelemetry, #{}),
    with_listener(Config, fun(Port, _Options) ->
        {200, <<"options-retained">>} = request(Port, "/traced", []),
        assert_bridge(wait_spans(2))
    end).

unsampled_parent(Config) ->
    application:set_env(kraft, opentelemetry, #{}),
    with_listener(Config, fun(Port, _Options) ->
        Trace = <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00">>,
        {200, <<"options-retained">>} = request(Port, "/traced", [
            {<<"traceparent">>, Trace}
        ]),
        timer:sleep(50),
        ?assertEqual([], ets:tab2list(?TABLE))
    end).

assert_bridge(Spans) ->
    [Root] = [S || #span{kind = server} = S <- Spans],
    [Child] = [S || #span{name = <<"handler.work">>} = S <- Spans],
    ?assertEqual(Root#span.trace_id, Child#span.trace_id),
    ?assertEqual(Root#span.span_id, Child#span.parent_span_id),
    ?assert(Root#span.start_time =< Child#span.start_time),
    ?assert(is_integer(Child#span.end_time)),
    Root.

remote_parent(Config) ->
    application:set_env(kraft, opentelemetry, #{}),
    with_listener(Config, fun(Port, _Options) ->
        Trace = <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01">>,
        {200, _} = request(Port, "/traced", [{<<"traceparent">>, Trace}]),
        Root = assert_bridge(wait_spans(2)),
        ?assertEqual(16#4bf92f3577b34da6a3ce929d0e0e4736, Root#span.trace_id),
        ?assertEqual(16#00f067aa0ba902b7, Root#span.parent_span_id),
        ?assertEqual(true, Root#span.parent_span_is_remote)
    end).

public_endpoint(Config) ->
    Opts = #{public_endpoint => true, handler_id => kraft_test},
    application:set_env(kraft, opentelemetry, Opts),
    with_listener(Config, fun(Port, _Options) ->
        [#{id := Id, config := HandlerConfig}] = telemetry:list_handlers([
            cowboy, request, start
        ]),
        ?assertEqual({opentelemetry_cowboy, kraft_test}, Id),
        ?assertEqual(true, maps:get(public_endpoint, HandlerConfig)),
        Trace = <<"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00">>,
        {200, _} = request(Port, "/traced", [{<<"traceparent">>, Trace}]),
        Root = assert_bridge(wait_spans(2)),
        ?assertNotEqual(
            16#4bf92f3577b34da6a3ce929d0e0e4736, Root#span.trace_id
        ),
        ?assertEqual(undefined, Root#span.parent_span_id),
        [Link] = otel_links:list(Root#span.links),
        ?assertEqual(16#4bf92f3577b34da6a3ce929d0e0e4736, Link#link.trace_id),
        ?assertEqual(16#00f067aa0ba902b7, Link#link.span_id)
    end).

restart(Config) ->
    public_endpoint(Config),
    ok = application:stop(kraft),
    ?assertEqual([], telemetry:list_handlers([cowboy, request, start])),
    ets:delete_all_objects(?TABLE),
    application:set_env(kraft, opentelemetry, false),
    disabled_by_default(Config).

with_listener(Config, Fun) ->
    {ok, _} = application:ensure_all_started(kraft),
    Listener = kraft:start(#{app => kraft, port => 0}, [
        {"/traced", {cowboy, kraft_test_trace_handler},
            {trace, <<"options-retained">>}},
        {"/devices/:id", {cowboy, kraft_test_trace_handler},
            <<"options-retained">>},
        {"/controller/:id", kraft_test_trace_handler, #{}},
        {"/static", {cowboy, cowboy_static},
            {file, filename:join(?config(data_dir, Config), "index.html")}}
    ]),
    unlink(Listener),
    try
        [Ref] = [
            R
         || {kraft_listener, kraft, _} = R <- maps:keys(ranch:info())
        ],
        Fun(ranch:get_port(Ref), ranch:get_protocol_options(Ref))
    after
        kraft:stop(Listener)
    end.

request(Port, Path, Headers) ->
    {ok, Conn} = gun:open("127.0.0.1", Port),
    try
        {ok, _} = gun:await_up(Conn),
        Ref = gun:get(Conn, Path, Headers),
        case gun:await(Conn, Ref) of
            {response, fin, Status, _} ->
                {Status, <<>>};
            {response, nofin, Status, _} ->
                {ok, Body} = gun:await_body(Conn, Ref),
                {Status, Body}
        end
    after
        gun:close(Conn)
    end.

wait_span() ->
    [Span] = wait_spans(1),
    Span.

wait_spans(Count) ->
    wait_spans(Count, erlang:monotonic_time(millisecond) + 5000).

wait_spans(Count, Deadline) ->
    Spans = ets:tab2list(?TABLE),
    case length(Spans) =:= Count of
        true ->
            Spans;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    timer:sleep(10),
                    wait_spans(Count, Deadline);
                false ->
                    ct:fail(missing_span)
            end
    end.

assert_http(Root, Path, Status) ->
    ?assertEqual(server, Root#span.kind),
    ?assertEqual('GET', Root#span.name),
    ?assert(is_integer(Root#span.end_time)),
    Attrs = otel_attributes:map(Root#span.attributes),
    ?assertEqual(Path, maps:get('url.path', Attrs)),
    ?assertEqual(Status, maps:get('http.response.status_code', Attrs)),
    ?assertNot(maps:is_key('http.route', Attrs)),
    Attrs.
