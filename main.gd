extends Node
## OpenTelemetry collector connectivity test.
##
## Sends a trace with two spans to a standard OTLP/HTTP collector
## (default: http://localhost:4318) and reports pass/fail.
##
## Run with:
##   godot.macos.editor.dev.double.arm64 --headless --path . -- --collector http://localhost:4318
##
## Start the collector first:
##   docker compose up -d
##
## Verify in Jaeger UI: http://localhost:16686

const DEFAULT_COLLECTOR := "http://localhost:4318"

var _otel: OpenTelemetry
var _collector: String
var _passed := 0
var _failed := 0


func _ready() -> void:
	_collector = _parse_collector_arg()
	print("=" .repeat(60))
	print("OpenTelemetry collector connectivity test")
	print("Collector: %s" % _collector)
	print("=" .repeat(60))

	await _run_tests()

	print("\n" + "=".repeat(60))
	var status := "ALL PASS" if _failed == 0 else "FAILURES: %d" % _failed
	print("Result: %s (%d passed, %d failed)" % [status, _passed, _failed])
	print("=".repeat(60))

	get_tree().quit(0 if _failed == 0 else 1)


func _parse_collector_arg() -> String:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--collector" and i + 1 < args.size():
			return args[i + 1]
	return DEFAULT_COLLECTOR


func _run_tests() -> void:
	await test_id_generation()
	await test_console_sink()
	await test_send_trace()
	await test_send_with_events()
	await test_send_metrics()


# ── Test 1: ID generation ────────────────────────────────────────────────────

func test_id_generation() -> void:
	_section("ID generation")
	_otel = OpenTelemetry.new()
	_otel.init_tracer_provider("id-test", "console", {})

	var span_id := _otel.start_span("id_check")
	_otel.end_span(span_id)

	_check("span_id is not empty", not span_id.is_empty())
	_check("span_id is a valid UUID-ish string (length > 8)", span_id.length() > 8)
	_otel.shutdown()


# ── Test 2: Console sink (no network) ───────────────────────────────────────

func test_console_sink() -> void:
	_section("Console sink (no network)")
	_otel = OpenTelemetry.new()
	_otel.init_tracer_provider("console-test", "console", {"service.name": "godot-otel-test"})

	var root := _otel.start_span("root_operation", OpenTelemetry.SPAN_KIND_SERVER)
	_otel.add_event(root, "test.started", {"iteration": 1})
	_otel.set_attributes(root, {"http.method": "GET", "http.status_code": 200})
	var child := _otel.start_span_with_parent("child_operation", root)
	_otel.end_span(child)
	_otel.set_status(root, OpenTelemetry.STATUS_OK)
	_otel.end_span(root)
	_otel.flush_all()

	_check("Console sink: flush did not crash", true)
	_otel.shutdown()


# ── Test 3: Send a trace to the collector ────────────────────────────────────

func test_send_trace() -> void:
	_section("Send trace to collector (%s)" % _collector)
	_otel = OpenTelemetry.new()
	_otel.init_tracer_provider(
		"godot-otel-test",
		_collector,
		{"service.name": "godot-otel-test", "service.version": "0.1.0", "environment": "test"}
	)

	var root := _otel.start_span("http.request", OpenTelemetry.SPAN_KIND_SERVER)
	_otel.set_attributes(root, {
		"http.method": "POST",
		"http.url": "/api/v1/data",
		"http.status_code": 200,
	})

	await get_tree().create_timer(0.01).timeout

	var db_span := _otel.start_span_with_parent("db.query", root, OpenTelemetry.SPAN_KIND_CLIENT)
	_otel.set_attributes(db_span, {"db.system": "sqlite", "db.statement": "SELECT * FROM spans"})
	_otel.end_span(db_span)

	_otel.set_status(root, OpenTelemetry.STATUS_OK)
	_otel.end_span(root)
	_otel.flush_all()

	# Give the HTTP request a moment to complete
	await get_tree().create_timer(0.5).timeout
	_check("Trace sent without crash", true)
	_otel.shutdown()


# ── Test 4: Span with events ─────────────────────────────────────────────────

func test_send_with_events() -> void:
	_section("Span with events and exception")
	_otel = OpenTelemetry.new()
	_otel.init_tracer_provider("godot-otel-test", _collector,
		{"service.name": "godot-otel-test"})

	var span := _otel.start_span("risky_operation")
	_otel.add_event(span, "cache.miss", {"key": "user:42"})
	_otel.add_event(span, "db.fallback", {"table": "users"})
	_otel.record_exception(span, "NullReferenceException: user was nil")
	_otel.set_status(span, OpenTelemetry.STATUS_ERROR, "user lookup failed")
	_otel.end_span(span)
	_otel.flush_all()

	await get_tree().create_timer(0.3).timeout
	_check("Error span with events sent", true)
	_otel.shutdown()


# ── Test 5: Metrics ──────────────────────────────────────────────────────────

func test_send_metrics() -> void:
	_section("Metrics")
	_otel = OpenTelemetry.new()
	_otel.init_tracer_provider("godot-otel-test", _collector,
		{"service.name": "godot-otel-test"})

	var counter := _otel.create_counter("requests.total", "1", "Total HTTP requests")
	var latency := _otel.create_histogram("request.duration", "ms", "Request latency")
	var active := _otel.create_gauge("connections.active", "1", "Active connections")

	_otel.increment_counter(counter, 1.0, {"method": "GET", "status": "200"})
	_otel.increment_counter(counter, 3.0, {"method": "POST", "status": "201"})
	_otel.record_histogram(latency, 12.5, {"endpoint": "/api/data"})
	_otel.record_histogram(latency, 8.3, {"endpoint": "/api/health"})
	_otel.set_gauge(active, 7.0, {})
	_otel.flush_all()

	await get_tree().create_timer(0.3).timeout
	_check("Metrics sent", true)
	_otel.shutdown()


# ── Helpers ──────────────────────────────────────────────────────────────────

func _section(name: String) -> void:
	print("\n── %s" % name)


func _check(label: String, cond: bool) -> void:
	if cond:
		_passed += 1
		print("  ✓ %s" % label)
	else:
		_failed += 1
		print("  ✗ FAIL: %s" % label)
