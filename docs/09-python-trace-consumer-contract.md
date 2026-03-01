# Python Trace Consumer — Integration Contract

> **Purpose**: This document defines the exact contract between the **OpenTelemetry Collector** (already running in Pathfinder) and a **Python service** that will receive and process distributed traces.  
> The Python service replaces (or runs alongside) Jaeger as the trace destination.

---

## 1. Architecture Overview

```
Angular UI  ──OTLP/HTTP──►┐
                           │
.NET API    ──OTLP/gRPC──►  OTel Collector  ──OTLP/gRPC──►  Python Service
                           │                                  (your new service)
                           └──OTLP/gRPC──►  Jaeger (optional, can be removed)
```

The Collector already fans out to multiple exporters. Adding the Python service is a **zero-change to the apps** — only `otel-collector-config.yaml` needs updating.

---

## 2. Transport Protocol

| Property | Value |
|---|---|
| Protocol | **OTLP over gRPC** (recommended) or OTLP over HTTP |
| gRPC port | `4317` (standard OTLP gRPC) |
| HTTP port | `4318` (standard OTLP HTTP, path `/v1/traces`) |
| Encoding | **Protobuf** (gRPC) / JSON or Protobuf (HTTP) |
| TLS | Optional — use `insecure: true` for local/Docker |
| Auth | Optional — Bearer token via `Authorization` header |

> **Recommendation**: Use **gRPC + Protobuf** for lowest overhead. Use HTTP/JSON only if you want human-readable payloads during development.

---

## 3. OTLP Protobuf Schema

The Collector sends the standard OpenTelemetry `ExportTraceServiceRequest` message.

### 3.1 Proto definition (simplified)

```protobuf
// opentelemetry/proto/collector/trace/v1/trace_service.proto

service TraceService {
  rpc Export(ExportTraceServiceRequest) returns (ExportTraceServiceResponse);
}

message ExportTraceServiceRequest {
  repeated opentelemetry.proto.trace.v1.ResourceSpans resource_spans = 1;
}

message ResourceSpans {
  opentelemetry.proto.resource.v1.Resource resource = 1;
  repeated ScopeSpans scope_spans = 2;
  string schema_url = 3;
}

message ScopeSpans {
  opentelemetry.proto.common.v1.InstrumentationScope scope = 1;
  repeated Span spans = 2;
  string schema_url = 3;
}

message Span {
  bytes  trace_id              = 1;   // 16 bytes, big-endian
  bytes  span_id               = 2;   // 8 bytes, big-endian
  string trace_state           = 3;
  bytes  parent_span_id        = 4;   // 8 bytes (empty = root span)
  string name                  = 5;
  SpanKind kind                = 6;
  fixed64 start_time_unix_nano = 7;
  fixed64 end_time_unix_nano   = 8;
  repeated KeyValue attributes = 9;
  repeated Event events        = 11;
  repeated Link links          = 12;
  Status status                = 15;
}

enum SpanKind {
  SPAN_KIND_UNSPECIFIED = 0;
  SPAN_KIND_INTERNAL    = 1;
  SPAN_KIND_SERVER      = 2;
  SPAN_KIND_CLIENT      = 3;
  SPAN_KIND_PRODUCER    = 4;
  SPAN_KIND_CONSUMER    = 5;
}

message Status {
  string message = 2;
  enum StatusCode {
    STATUS_CODE_UNSET = 0;
    STATUS_CODE_OK    = 1;
    STATUS_CODE_ERROR = 2;
  }
  StatusCode code = 3;
}
```

Full proto files: [opentelemetry-proto on GitHub](https://github.com/open-telemetry/opentelemetry-proto)

---

## 4. Actual Span Payload — What Pathfinder Sends

### 4.1 Resource Attributes (per service)

These are attached to every span from a given service:

| Attribute | Example Value | Source |
|---|---|---|
| `service.name` | `pathfinder-api` | `OTEL_SERVICE_NAME` env var |
| `service.name` | `pathfinder-ui` | Angular OTel SDK |
| `service.name` | `pathfinder-ui-zoneless` | Angular OTel SDK |
| `telemetry.sdk.name` | `opentelemetry` | Auto |
| `telemetry.sdk.language` | `dotnet` / `webjs` | Auto |
| `telemetry.sdk.version` | e.g. `1.9.0` | Auto |
| `process.runtime.name` | `dotnet` | Auto (.NET) |

### 4.2 Span Attributes — .NET API (HTTP spans)

The .NET auto-instrumentation emits these standard semantic convention attributes:

| Attribute | Example | Notes |
|---|---|---|
| `http.request.method` | `GET` | HTTP method |
| `http.route` | `/api/health` | Matched route template |
| `http.response.status_code` | `200` | Response status |
| `url.scheme` | `http` | |
| `url.path` | `/api/health` | |
| `server.address` | `localhost` | |
| `server.port` | `8080` | |
| `network.protocol.version` | `1.1` | |

**On error**, the span also gets a `status` of `STATUS_CODE_ERROR` **and** a span event named `"exception"` carrying the full stacktrace:

```json
{
  "status": {
    "code": "STATUS_CODE_ERROR",
    "message": "Object reference not set to an instance of an object."
  },
  "events": [
    {
      "name": "exception",
      "time_unix_nano": 1708265123456000000,
      "attributes": {
        "exception.type":       "System.NullReferenceException",
        "exception.message":    "Object reference not set to an instance of an object.",
        "exception.stacktrace": "System.NullReferenceException: Object reference not set...\n   at PathfinderApi.Controllers.HealthController.Get() in /app/Controllers/HealthController.cs:line 42\n   at ..."
      }
    }
  ]
}
```

> **Important**: The stacktrace is in `span.events[].attributes["exception.stacktrace"]`, **not** in `span.attributes`. You must iterate `span.events` to find it.

### 4.3 Span Attributes — Angular UI (browser spans)

| Attribute | Example | Notes |
|---|---|---|
| `http.method` | `GET` | (older convention, browser SDK) |
| `http.url` | `http://localhost:5215/api/health` | Full URL |
| `http.status_code` | `200` | |
| `component` | `xml-http-request` | |

### 4.4 Trace / Span ID format

- **Trace ID**: 16 bytes → hex string = 32 chars (e.g. `43f55bff415342924c67617d96d6eaa3`)
- **Span ID**: 8 bytes → hex string = 16 chars (e.g. `a1b2c3d4e5f60001`)
- **Parent Span ID**: same format; empty bytes = root span

---

## 5. Python Service Requirements

### 5.1 Endpoint to implement

Your Python service must expose a **gRPC server** implementing:

```
opentelemetry.proto.collector.trace.v1.TraceService
  └── Export(ExportTraceServiceRequest) → ExportTraceServiceResponse
```

Or, if using HTTP mode, a **POST endpoint**:
```
POST /v1/traces
Content-Type: application/x-protobuf   (or application/json)
```

### 5.2 Response contract

```protobuf
message ExportTraceServiceResponse {
  ExportTracePartialSuccess partial_success = 1;
}

message ExportTracePartialSuccess {
  int64  rejected_spans   = 1;  // 0 = all accepted
  string error_message    = 2;  // empty = no error
}
```

Return HTTP `200` / gRPC `OK` for success. The Collector will retry on `5xx` / gRPC `UNAVAILABLE`.

---

## 6. Python Implementation Quickstart

### 6.1 Dependencies

```bash
pip install \
  opentelemetry-sdk \
  opentelemetry-proto \
  grpcio \
  grpcio-tools \
  opentelemetry-exporter-otlp-proto-grpc
```

### 6.2 Minimal gRPC receiver skeleton

```python
# trace_receiver.py
import grpc
from concurrent import futures
from opentelemetry.proto.collector.trace.v1 import (
    trace_service_pb2,
    trace_service_pb2_grpc,
)
from opentelemetry.proto.trace.v1 import trace_pb2


def decode_id(b: bytes) -> str:
    """Convert raw bytes to hex trace/span ID string."""
    return b.hex()


def get_attr(attributes, key: str) -> str:
    """Extract a string attribute value by key from a repeated KeyValue list."""
    for a in attributes:
        if a.key == key:
            return a.value.string_value
    return ""


class TraceServiceServicer(trace_service_pb2_grpc.TraceServiceServicer):
    def Export(self, request, context):
        for resource_spans in request.resource_spans:
            # ── Resource-level: which service sent this? ──────────────────
            service_name = get_attr(resource_spans.resource.attributes, "service.name") or "unknown"

            for scope_spans in resource_spans.scope_spans:
                for span in scope_spans.spans:
                    trace_id    = decode_id(span.trace_id)
                    span_id     = decode_id(span.span_id)
                    parent      = decode_id(span.parent_span_id) if span.parent_span_id else None
                    duration_ms = (span.end_time_unix_nano - span.start_time_unix_nano) / 1_000_000

                    # ── Span-level attributes (HTTP method, route, status code…) ──
                    attrs = {a.key: a.value.string_value for a in span.attributes}

                    print(f"[{service_name}] {span.name}")
                    print(f"  trace_id  : {trace_id}")
                    print(f"  span_id   : {span_id}")
                    print(f"  parent_id : {parent}")
                    print(f"  duration  : {duration_ms:.2f} ms")
                    print(f"  status    : {span.status.code} — {span.status.message}")
                    print(f"  attrs     : {attrs}")

                    # ── Span events — this is where .NET sends the stacktrace ──
                    for event in span.events:
                        event_attrs = {a.key: a.value.string_value for a in event.attributes}

                        if event.name == "exception":
                            print(f"  !! EXCEPTION EVENT !!")
                            print(f"     type      : {event_attrs.get('exception.type', '')}")
                            print(f"     message   : {event_attrs.get('exception.message', '')}")
                            # Full .NET stacktrace is here ↓
                            stacktrace = event_attrs.get("exception.stacktrace", "")
                            print(f"     stacktrace:\n{stacktrace}")
                        else:
                            print(f"  event: {event.name} — {event_attrs}")

        return trace_service_pb2.ExportTraceServiceResponse()


def serve(port: int = 4317):
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    trace_service_pb2_grpc.add_TraceServiceServicer_to_server(
        TraceServiceServicer(), server
    )
    server.add_insecure_port(f"[::]:{port}")
    server.start()
    print(f"Python trace receiver listening on port {port}")
    server.wait_for_termination()


if __name__ == "__main__":
    serve()
```

---

## 7. OTel Collector Config Update

Edit `otel-collector-config.yaml` to add the Python service as an exporter:

```yaml
exporters:
  # existing Jaeger exporter (keep or remove)
  otlp/jaeger:
    endpoint: jaeger:4317
    tls:
      insecure: true

  # NEW: Python trace consumer
  otlp/python:
    endpoint: python-trace-service:4317   # hostname:port of your Python service
    tls:
      insecure: true                       # set false + add cert if using TLS

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters:
        - otlp/jaeger       # remove this line to stop sending to Jaeger
        - otlp/python       # ← add this
        - debug
```

> If running locally with Docker Compose, add your Python service to `docker-compose.yml` and use the service name as the hostname.

---

## 8. Docker Compose Integration

```yaml
# Add to docker-compose.yml
services:
  python-trace-service:
    build:
      context: ./python-trace-service   # your Python project folder
      dockerfile: Dockerfile
    container_name: python-trace-service
    ports:
      - "4321:4317"   # expose gRPC externally (optional)
    networks:
      - pathfinder-network
```

Then in `otel-collector-config.yaml`, use `python-trace-service:4317` as the endpoint.

---

## 9. Data Flow Timing

| Stage | Typical Latency |
|---|---|
| App → Collector | < 5 ms (gRPC, local) |
| Collector batch flush | up to **5 seconds** (configured `timeout: 5s`) |
| Collector → Python | < 5 ms (gRPC, local) |
| **Total end-to-end** | **≤ 5 seconds** after span ends |

The Collector batches spans with `send_batch_size: 1024` or `timeout: 5s`, whichever comes first.

---

## 10. Checklist for Python Service Author

- [ ] Implement `TraceService.Export` gRPC method (or POST `/v1/traces` for HTTP)
- [ ] Return `ExportTraceServiceResponse` with `rejected_spans = 0` on success
- [ ] Handle `resource_spans → scope_spans → spans` nesting
- [ ] Decode `trace_id` and `span_id` from bytes to hex strings
- [ ] Parse `resource.attributes` to extract `service.name`
- [ ] Parse `span.attributes` for HTTP/custom attributes (method, route, status code)
- [ ] Iterate `span.events` and check `event.name == "exception"`
  - [ ] Extract `exception.type` from event attributes
  - [ ] Extract `exception.message` from event attributes
  - [ ] Extract `exception.stacktrace` from event attributes ← **full .NET stacktrace is here**
- [ ] Check `span.status.code` for error detection (`STATUS_CODE_ERROR = 2`)
- [ ] Expose port `4317` (gRPC) inside Docker network
- [ ] Register service name in `otel-collector-config.yaml` exporter
