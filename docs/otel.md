# OpenTelemetry

Tracing is disabled by default. Configure it before starting Kraft:

```erlang
{kraft, [{opentelemetry, #{}}]}.
```

A map enables tracing; `false` disables it. Options pass directly to
`opentelemetry_cowboy:setup/1`. For example, start a new trace and link incoming
context instead of using it as the parent:

```erlang
{kraft, [{opentelemetry, #{public_endpoint => true}}]}.
```

Kraft installs `cowboy_telemetry_h` and a context bridge on each listener.
Handler spans inherit the HTTP server span's context. `opentelemetry_cowboy`
owns the server span's names, attributes, and lifecycle.

Configure sampling, resource attributes, and export in the hosting application.
For OTLP, start the exporter before the SDK and Kraft.

Include `{opentelemetry_cowboy, load}` in the release's applications so tracing
can be enabled at runtime.

Run the Common Test suite:

```sh
rebar3 ct --suite test/kraft_opentelemetry_SUITE.erl
```

It uses an in-memory exporter and covers configuration, span nesting, sampling,
incoming context, public endpoints, and restart.

