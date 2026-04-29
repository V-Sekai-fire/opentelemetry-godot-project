# opentelemetry-godot-project

Integration test for the `open_telemetry` Godot module.  Sends real OTLP
traces, metrics, and logs to a standard OpenTelemetry Collector and verifies
the connection end-to-end.

## Prerequisites

| Tool | Purpose |
|---|---|
| Custom Godot build | `opentelemetry-godot` with `open_telemetry` module |
| Docker + Compose | Runs the collector stack |

Build the Godot binary if you haven't already:

```sh
cd ../opentelemetry-godot
scons target=editor dev_mode=yes arch=arm64 -j11
```

## Quick start

```sh
cd opentelemetry-godot-project
./run_test.sh
```

This starts the collector stack, runs all tests, and prints a pass/fail
summary.  Traces appear in Jaeger at **http://localhost:16686** — search for
service **godot-otel-test**.

## Stack

```
Godot (OTLP/HTTP :4318)
  └─► otelcol-contrib  (receiver → batch → exporter)
        ├─► Jaeger all-in-one  http://localhost:16686
        └─► debug exporter     (stdout of otelcol container)
```

| Service | Port | URL |
|---|---|---|
| OTLP/HTTP receiver | 4318 | `http://localhost:4318` |
| OTLP/gRPC receiver | 4317 | — |
| Jaeger UI | 16686 | http://localhost:16686 |
| otelcol zPages | 55679 | http://localhost:55679/debug/tracez |

Start / stop independently:

```sh
docker compose up -d      # start
docker compose down       # stop and remove containers
docker compose logs -f    # stream collector logs
```

## Test cases

| # | Name | What it checks |
|---|---|---|
| 1 | ID generation | `OTelSpan.generate_trace_id()` returns 32 hex chars; `generate_span_id()` returns 16 |
| 2 | Console sink | Flush with `hostname="console"` does not crash |
| 3 | Send trace | Root span + child sent to `http://localhost:4318/v1/traces` |
| 4 | Events & exception | `add_event`, `record_exception`, error status code |
| 5 | Metrics | Counter, histogram, gauge sent to `/v1/metrics` |

Run against a different collector:

```sh
./run_test.sh http://my-collector:4318
# or
godot.macos.editor.dev.double.arm64 --headless --path . -- --collector http://my-collector:4318
```

## Files

```
opentelemetry-godot-project/
├── project.godot       Godot 4.7 project (GL Compatibility renderer)
├── main.tscn           Root scene — loads main.gd
├── main.gd             All test cases
├── docker-compose.yml  otelcol-contrib + Jaeger
├── otelcol-config.yaml Collector pipeline config
└── run_test.sh         One-command test runner
```

## Pass condition

```
Result: ALL PASS (6 passed, 0 failed)
```

Exit code 0 on success, 1 on any failure.

## Relation to CI

The `open_telemetry` unit tests (`--test --test-case="*OTelSpan*"`) verify the
C++ layer (ID format, span serialisation, etc.) without a live collector.  This
project adds the next layer: a real HTTP round-trip to a real OTLP endpoint.

Both must pass before changes to `otel_span.cpp` or `open_telemetry.cpp` are
considered complete.
