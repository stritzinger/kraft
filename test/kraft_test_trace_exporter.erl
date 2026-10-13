-module(kraft_test_trace_exporter).
-behaviour(otel_exporter_traces).

-export([init/1, export/3, shutdown/1]).

init(Table) ->
    {ok, Table}.

export(Spans, _Resource, Table) ->
    true = ets:insert(Table, ets:tab2list(Spans)),
    success.

shutdown(_Table) ->
    ok.
