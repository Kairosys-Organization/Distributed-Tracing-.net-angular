# Observability Guide — Distributed Tracing

## Architecture

All applications send traces to the **OpenTelemetry Collector**, which acts as the single aggregation point and fans out to two consumers.

```
┌─────────────────────────────────────────────────────────────────────┐
│                         APPLICATIONS                                │
│                                                                     │
│  .NET API ──────────────────(gRPC OTLP)────────────────────┐        │
│  Angular UI ────────────────(HTTP OTLP)────────────────────┤        │
│  Angular Zoneless UI ───────(HTTP OTLP)────────────────────┘        │
└──────────────────────────────────┬──────────────────────────────────┘
                                   │
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      OTel Collector                                 │
│                                                                     │
│   Receives:  gRPC :4317 (internal)  │  HTTP :4318 (internal)       │
│   Exposes:   gRPC :4319 (host)      │  HTTP :4320 (host)           │
│                                                                     │
│   Pipeline A  → batch processor (5s)          → Jaeger             │
│   Pipeline B  → tail_sampling (10s wait)      → Custom App (full)  │
└──────────────┬─────────────────────────────────────────────────────┘
               │
       ┌───────┴────────┐
       ▼                ▼
   Jaeger UI      Custom App
   :16686         receives FULL traces
                  (all spans of a trace delivered together)
```

---

## Quick Start

### 1. Configure `.env`

```bash
cp .env.example .env
```

Edit `.env` for your environment:

```env
# URL browsers use to reach the API
API_URL=http://YOUR_SERVER_IP:5215/api

# URL browsers use to send traces (OTel Collector HTTP)
OTEL_COLLECTOR_HTTP_URL=http://YOUR_SERVER_IP:4320/v1/traces

# Service name shown in Jaeger
DOTNET_SERVICE_NAME=pathfinder-api

# Where collector pushes FULL traces to your custom app (gRPC OTLP)
CUSTOM_CONSUMER_ENDPOINT=YOUR_CUSTOM_APP_HOST:4317
```

### 2. Start the Stack

```bash
docker compose up -d
```

### 3. Verify

| Service | URL |
|---|---|
| **Jaeger UI** | http://localhost:16686 |
| **Angular UI** | http://localhost:4200 |
| **Angular UI (Zoneless)** | http://localhost:4201 |
| **API** | http://localhost:5215/api/health |

---

## Port Reference

| Port | Protocol | Direction | Purpose |
|------|----------|-----------|---------|
| `4319` | gRPC | **← inbound to collector** | .NET / Java / Go apps send traces here |
| `4320` | HTTP | **← inbound to collector** | Browser / REST clients send traces here |
| `4319` | gRPC | **→ outbound from collector** | Collector pushes to your custom app |
| `16686` | HTTP | — | Jaeger UI |

> **Inside Docker network:** use `otel-collector:4317` (gRPC) or `otel-collector:4318` (HTTP).
> **From any external app or host:** use `localhost:4319` (gRPC) or `http://localhost:4320` (HTTP).

---

## Configuring Your Custom App

The OTel Collector **pushes full traces** to your app via gRPC OTLP once all spans of a trace are collected (10s window).

Your app must expose an **OTLP gRPC receiver** on the port specified in `CUSTOM_CONSUMER_ENDPOINT`.

### Example: Python (opentelemetry-sdk)

```python
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter

# Your app acts as a RECEIVER — open a gRPC server on port 4317
# Use opentelemetry-collector or grpc server to receive on 0.0.0.0:4317
```

Or simply run your own OTel Collector as a sidecar that receives on `:4317` and forwards to your processing logic.

### Example: Changing the endpoint

In `.env`:
```env
CUSTOM_CONSUMER_ENDPOINT=192.168.1.100:4317
```

Then restart:
```bash
docker compose restart otel-collector
```

---

## Pipeline Details

### Pipeline A — Jaeger (fast)
```
All apps → Collector → batch (5s, 512 spans) → Jaeger
```
Spans appear in Jaeger within ~5 seconds.

### Pipeline B — Custom App (full trace)
```
All apps → Collector → tail_sampling (waits 10s) → Custom App
```
The collector **holds all spans** for a trace in memory until the trace is complete (decision window: 10s), then **sends the entire trace in one shot**. Your app receives the full distributed trace — not span by span.

---

## Sending Traces from Other Applications

Any application can send traces to the collector using standard OTLP:

### .NET / C#
```csharp
builder.Services.AddOpenTelemetry()
    .WithTracing(t => t
        .AddOtlpExporter(o => {
            o.Endpoint = new Uri("http://HOST:4319");  // gRPC
            o.Protocol = OtlpExportProtocol.Grpc;
        }));
```

### Python
```python
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
exporter = OTLPSpanExporter(endpoint="HOST:4319", insecure=True)
```

### Java (Spring Boot)
```yaml
management.opentelemetry.tracing.endpoint: http://HOST:4319
```

### JavaScript / Node.js
```js
new OTLPTraceExporter({ url: 'http://HOST:4320/v1/traces' })
```

Replace `HOST` with your server IP or `localhost`.

---

## Production Deployment

Use `docker-compose.prod.yml`:

```bash
docker compose -f docker-compose.prod.yml up -d
```

The prod file uses the same `.env` variables — only difference is stricter healthchecks and `ASPNETCORE_ENVIRONMENT=Production`.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Browser 503 on OTEL_URL | Wrong port in `.env` | Set `OTEL_COLLECTOR_HTTP_URL=http://HOST:4320/v1/traces` |
| No traces in Jaeger | Collector not reaching Jaeger | `docker logs pathfinder-otel-collector` |
| Custom app not receiving | Wrong `CUSTOM_CONSUMER_ENDPOINT` | Check your app listens on that port with gRPC OTLP |
| CORS error in browser | Origin not allowed | Collector CORS is set to `http://*` — check browser network tab |
| `window.env not loaded` in console | `env.js` not in `index.html` | Check `<script src="assets/env.js">` is in `<head>` |

### Useful Commands

```bash
# Check all containers
docker compose ps

# Watch collector logs (shows every trace received)
docker logs -f pathfinder-otel-collector

# Verify env vars injected into Angular container
docker exec pathfinder-ui cat /usr/share/nginx/html/assets/env.js

# Restart only the collector (after changing otel-collector-config.yaml or .env)
docker compose restart otel-collector
```
