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
