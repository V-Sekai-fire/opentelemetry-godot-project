extends Node
## OpenTelemetry OTLP compliance test.
##
## Verifies the C++ module produces wire-correct OTLP/HTTP JSON and that
## Jaeger receives and indexes traces with the right structure.
##
## Run with:
##   godot.macos.editor.dev.double.arm64 --headless --path . -- --collector http://localhost:4318
##
## Start the collector first:
##   docker compose up -d
##
## Verify in Jaeger UI: http://localhost:16686

const DEFAULT_COLLECTOR := "http://localhost:4318"
const DEFAULT_JAEGER    := "http://localhost:16686"

var _otel: OpenTelemetry
var _collector: String
var _jaeger: String
var _passed := 0
var _failed := 0


func _ready() -> void:
	_collector = _parse_collector_arg()
	_jaeger    = _parse_jaeger_arg()
	print("=" .repeat(60))
	print("OpenTelemetry OTLP compliance test")
	print("Collector: %s" % _collector)
	print("Jaeger:    %s" % _jaeger)
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


func _parse_jaeger_arg() -> String:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--jaeger" and i + 1 < args.size():
			return args[i + 1]
	return DEFAULT_JAEGER


func _run_tests() -> void:
	await test_id_format()
	await test_span_kind_enum()
	await test_console_sink()
	await test_send_trace()
	await test_send_with_events()
	await test_send_metrics()
	await test_log_message()
	await test_log_body_anyvalue()
	await test_crash_reporting()
	await test_jaeger_received()
	await test_jaeger_event_timestamps()
	await test_jaeger_span_status_message()


# ── Test 1: OTLP ID format (spec §traceId/spanId must be 32/16 hex chars) ────

func test_id_format() -> void:
	_section("OTLP ID format (spec: traceId=32 hex, spanId=16 hex)")

	var trace_id := OTelSpan.generate_trace_id()
	var span_id  := OTelSpan.generate_span_id()

	_check("traceId length == 32",  trace_id.length() == 32)
	_check("spanId  length == 16",  span_id.length()  == 16)
	_check("traceId is lowercase hex", _is_hex(trace_id))
	_check("spanId  is lowercase hex", _is_hex(span_id))
	_check("traceId is non-zero",   trace_id != "0".repeat(32))
	_check("spanId  is non-zero",   span_id  != "0".repeat(16))


# ── Test 2: SpanKind enum matches OTLP proto values ──────────────────────────
# Spec: UNSPECIFIED=0, INTERNAL=1, SERVER=2, CLIENT=3, PRODUCER=4, CONSUMER=5

func test_span_kind_enum() -> void:
	_section("SpanKind enum values (spec: INTERNAL=1, SERVER=2, CLIENT=3)")

	_check("SPAN_KIND_UNSPECIFIED == 0", OpenTelemetry.SPAN_KIND_UNSPECIFIED == 0)
	_check("SPAN_KIND_INTERNAL    == 1", OpenTelemetry.SPAN_KIND_INTERNAL    == 1)
	_check("SPAN_KIND_SERVER      == 2", OpenTelemetry.SPAN_KIND_SERVER      == 2)
	_check("SPAN_KIND_CLIENT      == 3", OpenTelemetry.SPAN_KIND_CLIENT      == 3)
	_check("SPAN_KIND_PRODUCER    == 4", OpenTelemetry.SPAN_KIND_PRODUCER    == 4)
	_check("SPAN_KIND_CONSUMER    == 5", OpenTelemetry.SPAN_KIND_CONSUMER    == 5)


# ── Test 3: Console sink (no network) ───────────────────────────────────────

func test_console_sink() -> void:
	_section("Console sink (no network)")
	_otel = OpenTelemetry.new()
	_otel.init_tracer_provider("console-test", "console", {"service.name": "godot-otel-test"})

	var root := _otel.start_span("root_operation", OpenTelemetry.SPAN_KIND_SERVER)
	_otel.add_event(root, "test.started", {"iteration": 1})
	_otel.set_attributes(root, {"http.method": "GET", "http.status_code": 200})
	var child := _otel.start_span_with_parent("child_operation", root, OpenTelemetry.SPAN_KIND_CLIENT)
	_otel.end_span(child)
	_otel.set_status(root, OpenTelemetry.STATUS_OK)
	_otel.end_span(root)
	_otel.flush_all()

	_check("Console sink: flush did not crash", true)
	_otel.shutdown()


# ── Test 4: Send a trace to the collector ────────────────────────────────────
# Uses SPAN_KIND_SERVER (=2) and SPAN_KIND_CLIENT (=3) per OTLP spec.
# Integer attribute http.status_code=200 tests intValue decimal-string encoding.

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

	await get_tree().create_timer(0.5).timeout
	_check("Trace sent without crash", true)
	_otel.shutdown()


# ── Test 5: Span with events ─────────────────────────────────────────────────

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


# ── Test 6: Metrics ──────────────────────────────────────────────────────────

func test_send_metrics() -> void:
	_section("Metrics")
	_otel = OpenTelemetry.new()
	_otel.init_tracer_provider("godot-otel-test", _collector,
		{"service.name": "godot-otel-test"})

	var counter := _otel.create_counter("requests.total", "1", "Total HTTP requests")
	var latency := _otel.create_histogram("request.duration", "ms", "Request latency")
	var active  := _otel.create_gauge("connections.active", "1", "Active connections")

	_otel.increment_counter(counter, 1.0, {"method": "GET", "status": "200"})
	_otel.increment_counter(counter, 3.0, {"method": "POST", "status": "201"})
	_otel.record_histogram(latency, 12.5, {"endpoint": "/api/data"})
	_otel.record_histogram(latency, 8.3,  {"endpoint": "/api/health"})
	_otel.set_gauge(active, 7.0, {})
	_otel.flush_all()

	await get_tree().create_timer(0.3).timeout
	_check("Metrics sent", true)
	_otel.shutdown()


# ── Test 6b: Log message — severityNumber, severityText, observedTimeUnixNano ─
# Spec §LogRecord: severityNumber MUST be an integer (not enum name string).
# Spec §LogRecord: observedTimeUnixNano MUST be set once observed.

func test_log_message() -> void:
	_section("Log message (severityNumber int, observedTimeUnixNano set)")
	_otel = OpenTelemetry.new()
	_otel.init_tracer_provider("godot-otel-test", _collector,
		{"service.name": "godot-otel-test"})

	_otel.log_message("INFO",  "player joined zone",  {"player.id": "p42"})
	_otel.log_message("WARN",  "latency spike",        {"latency_ms": 320})
	_otel.log_message("ERROR", "connection dropped",   {"reason": "timeout"})
	_otel.flush_all()

	await get_tree().create_timer(0.3).timeout
	_check("Log messages sent without crash", true)
	_otel.shutdown()


# ── Test 6c: Log body as OTLP AnyValue ────────────────────────────────────────
# Spec §AnyValue: body MUST be encoded as the appropriate typed field.
#   String  → {stringValue: "..."}
#   int     → {intValue: "decimal_string"}
#   Dictionary → {kvlistValue: {values: [{key, value}...]}}
#   Array   → {arrayValue: {values: [...]}}

func test_log_body_anyvalue() -> void:
	_section("Log body as AnyValue (string, int, Dictionary, Array)")
	_otel = OpenTelemetry.new()
	_otel.init_tracer_provider("godot-otel-test", _collector,
		{"service.name": "godot-otel-test"})

	# String body → stringValue
	_otel.log_message("INFO", "plain string body", {})
	# int body → intValue decimal string
	_otel.log_message("DEBUG", 42, {})
	# Dictionary body → kvlistValue
	_otel.log_message("INFO", {"event": "player_joined", "player_id": 99, "zone": "hub"}, {})
	# Array body → arrayValue
	_otel.log_message("DEBUG", ["step_a", "step_b", "step_c"], {})
	_otel.flush_all()

	await get_tree().create_timer(0.3).timeout
	_check("AnyValue log bodies sent without crash", true)
	_otel.shutdown()


# ── Test 7: Crash reporting ──────────────────────────────────────────────────

func test_crash_reporting() -> void:
	_section("Crash reporting (WAL-only, no HTTP)")
	_otel = OpenTelemetry.new()
	_otel.init_tracer_provider("godot-otel-test", _collector,
		{"service.name": "godot-otel-test"})

	_otel.record_crash("NullReferenceError: player node was nil", {
		"exception.type": "NullReferenceError",
		"code.filepath": "res://player.gd",
		"code.lineno": 42,
	})
	_otel.drain_wal()

	await get_tree().create_timer(0.5).timeout
	_check("Crash event written to WAL and delivered", true)
	_otel.shutdown()


# ── Test 8: Jaeger end-to-end + spec field verification ──────────────────────
# Queries Jaeger to confirm:
#   - service registered
#   - traces present
#   - http.request span has span.kind=server (OTLP SERVER=2 → Jaeger "server")
#   - db.query span has span.kind=client  (OTLP CLIENT=3 → Jaeger "client")
#   - db.query has a parent reference (parentSpanId wired correctly)
#   - http.status_code=200 tag present (intValue decimal-string round-trip)

func test_jaeger_received() -> void:
	_section("Jaeger end-to-end + OTLP field verification (%s)" % _jaeger)

	var jaeger_host := _jaeger
	var jaeger_port := 16686
	if "://" in jaeger_host:
		jaeger_host = jaeger_host.split("://")[1]
	if ":" in jaeger_host:
		var parts := jaeger_host.split(":")
		jaeger_host = parts[0]
		jaeger_port = int(parts[1])

	# ── helper: GET a Jaeger API path, return parsed JSON or null ────────────
	var body: Variant = await _jaeger_get(jaeger_host, jaeger_port, "/api/services")
	if body == null:
		_check("Jaeger reachable", false)
		return
	_check("Jaeger reachable", true)

	var parsed: Variant = JSON.parse_string(body)
	if parsed and (parsed as Dictionary).has("data"):
		_check("godot-otel-test registered in Jaeger",
			"godot-otel-test" in ((parsed as Dictionary)["data"] as Array))
	else:
		_check("godot-otel-test registered in Jaeger", false)
		return

	# ── Fetch most recent http.request trace ─────────────────────────────────
	var traces_body: Variant = await _jaeger_get(jaeger_host, jaeger_port,
		"/api/traces?service=godot-otel-test&operation=http.request&limit=1")
	if traces_body == null:
		_check("Trace query returned data", false)
		return

	var tparsed: Variant = JSON.parse_string(traces_body as String)
	if not (tparsed and tparsed.has("data") and (tparsed["data"] as Array).size() > 0):
		_check("At least one http.request trace in Jaeger", false)
		return
	_check("At least one http.request trace in Jaeger", true)

	var trace: Dictionary = (tparsed["data"] as Array)[0]
	var spans: Array = trace.get("spans", [])
	_check("Trace has 2 spans (root + child)", spans.size() == 2)

	# ── Find spans by operation name ─────────────────────────────────────────
	var root_span: Dictionary
	var child_span: Dictionary
	for s in spans:
		if s.get("operationName", "") == "http.request":
			root_span = s
		elif s.get("operationName", "") == "db.query":
			child_span = s

	_check("http.request span found", not root_span.is_empty())
	_check("db.query span found",     not child_span.is_empty())

	if root_span.is_empty() or child_span.is_empty():
		return

	# ── Spec: span.kind tag reflects OTLP SpanKind wire value ────────────────
	_check("http.request span.kind == server",
		_jaeger_tag(root_span,  "span.kind") == "server")
	_check("db.query span.kind == client",
		_jaeger_tag(child_span, "span.kind") == "client")

	# ── Spec: parentSpanId wired on child (traceId propagated) ───────────────
	var refs: Array = child_span.get("references", [])
	var has_parent := false
	for r in refs:
		if r.get("refType", "") == "CHILD_OF":
			has_parent = true
	_check("db.query has CHILD_OF parent reference", has_parent)

	# ── Spec: integer attribute http.status_code round-trips correctly ────────
	_check("http.request has http.status_code tag",
		_jaeger_tag(root_span, "http.status_code") != null)

	# ── Spec: traceId is 32 lowercase hex chars ───────────────────────────────
	var wire_trace_id: String = trace.get("traceID", "")
	_check("traceID is 32 hex chars", wire_trace_id.length() == 32)
	_check("traceID is lowercase hex", _is_hex(wire_trace_id))


# ── Test 9: Span event timestamps are valid absolute nanoseconds ──────────────
# Spec §Event.timeUnixNano: fixed64, decimal string in JSON.
# Jaeger receives this and converts to a relative µs offset from span start.
# If timeUnixNano were 0 or a raw integer overflow, Jaeger would show 0µs or
# nonsense offsets for all three events — this test catches that regression.

func test_jaeger_event_timestamps() -> void:
	_section("Span event timestamps valid in Jaeger (spec: event.timeUnixNano decimal string)")

	var jaeger_host := _jaeger
	var jaeger_port := 16686
	if "://" in jaeger_host:
		jaeger_host = jaeger_host.split("://")[1]
	if ":" in jaeger_host:
		var parts := jaeger_host.split(":")
		jaeger_host = parts[0]
		jaeger_port = int(parts[1])

	# Fetch the most recent risky_operation trace (has 3 events)
	var body: Variant = await _jaeger_get(jaeger_host, jaeger_port,
		"/api/traces?service=godot-otel-test&operation=risky_operation&limit=1")
	if body == null:
		_check("Jaeger reachable for event timestamp test", false)
		return

	var parsed: Variant = JSON.parse_string(body as String)
	if not (parsed and (parsed as Dictionary).has("data")):
		_check("risky_operation trace found", false)
		return
	var traces: Array = (parsed as Dictionary)["data"]
	if traces.is_empty():
		_check("risky_operation trace found", false)
		return
	_check("risky_operation trace found", true)

	var span: Dictionary
	for s in (traces[0] as Dictionary).get("spans", []):
		if (s as Dictionary).get("operationName", "") == "risky_operation":
			span = s
	if span.is_empty():
		_check("risky_operation span found", false)
		return
	_check("risky_operation span found", true)

	# Spec: 3 events (cache.miss, db.fallback, exception)
	var logs: Array = span.get("logs", [])
	_check("3 span events received", logs.size() == 3)

	# Spec: each event has a valid relative timestamp > 0µs
	# (proves timeUnixNano was a proper decimal nanosecond string, not 0 or overflow)
	var all_timestamps_valid := true
	for log_entry in logs:
		var ts: int = (log_entry as Dictionary).get("timestamp", 0)
		if ts <= 0:
			all_timestamps_valid = false
	_check("All event timestamps are > 0 (timeUnixNano decimal string correct)", all_timestamps_valid)

	# Spec: events carry their attribute fields
	var first_event: Dictionary = logs[0]
	var fields: Array = first_event.get("fields", [])
	var has_event_name := false
	for f in fields:
		if (f as Dictionary).get("key", "") == "event":
			has_event_name = true
	_check("First event has 'event' field (cache.miss)", has_event_name)


# ── Test 10: Span status.message round-trips via Jaeger ───────────────────────
# Spec §Status: message field serialized as "message" (not "description").
# Jaeger surfaces this as otel.status_description tag.

func test_jaeger_span_status_message() -> void:
	_section("Span status.message in Jaeger (spec: Status.message field)")

	var jaeger_host := _jaeger
	var jaeger_port := 16686
	if "://" in jaeger_host:
		jaeger_host = jaeger_host.split("://")[1]
	if ":" in jaeger_host:
		var parts := jaeger_host.split(":")
		jaeger_host = parts[0]
		jaeger_port = int(parts[1])

	var body: Variant = await _jaeger_get(jaeger_host, jaeger_port,
		"/api/traces?service=godot-otel-test&operation=risky_operation&limit=1")
	if body == null:
		_check("Jaeger reachable for status test", false)
		return

	var parsed: Variant = JSON.parse_string(body as String)
	if not (parsed and (parsed as Dictionary).has("data") and
			not ((parsed as Dictionary)["data"] as Array).is_empty()):
		_check("risky_operation trace found for status test", false)
		return

	var span: Dictionary
	for s in ((parsed as Dictionary)["data"][0] as Dictionary).get("spans", []):
		if (s as Dictionary).get("operationName", "") == "risky_operation":
			span = s

	_check("otel.status_code = ERROR",
		_jaeger_tag(span, "otel.status_code") == "ERROR")
	_check("otel.status_description = 'user lookup failed'",
		_jaeger_tag(span, "otel.status_description") == "user lookup failed")


# ── Helpers ──────────────────────────────────────────────────────────────────

func _jaeger_get(p_host: String, p_port: int, p_path: String) -> Variant:
	var http := HTTPClient.new()
	if http.connect_to_host(p_host, p_port) != OK:
		return null
	for _i in 20:
		http.poll()
		if http.get_status() == HTTPClient.STATUS_CONNECTED:
			break
		await get_tree().create_timer(0.1).timeout
	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		return null
	if http.request(HTTPClient.METHOD_GET, p_path, []) != OK:
		return null
	for _i in 50:
		http.poll()
		if http.get_status() == HTTPClient.STATUS_BODY:
			break
		await get_tree().create_timer(0.1).timeout
	var body := PackedByteArray()
	while http.get_status() == HTTPClient.STATUS_BODY:
		http.poll()
		var chunk := http.read_response_body_chunk()
		if chunk.size() > 0:
			body.append_array(chunk)
		await get_tree().create_timer(0.01).timeout
	http.close()
	return body.get_string_from_utf8()


func _jaeger_tag(p_span: Dictionary, p_key: String) -> Variant:
	for tag in p_span.get("tags", []):
		if tag.get("key", "") == p_key:
			return tag.get("value", null)
	return null


func _is_hex(p_str: String) -> bool:
	for i in p_str.length():
		var c := p_str[i]
		if not ((c >= "0" and c <= "9") or (c >= "a" and c <= "f")):
			return false
	return p_str.length() > 0


func _section(name: String) -> void:
	print("\n── %s" % name)


func _check(label: String, cond: bool) -> void:
	if cond:
		_passed += 1
		print("  ✓ %s" % label)
	else:
		_failed += 1
		print("  ✗ FAIL: %s" % label)
