# OpenClaw Observability with AI Observe Stack

This guide walks through setting up full observability (traces, metrics, logs) for a locally-running [OpenClaw](https://openclaw.dev) instance using the AI Observe Stack.

## What's Included

| File | Description |
|------|-------------|
| [`otel-collector-log-config.yaml`](./otel-collector-log-config.yaml) | OTel Collector config for tailing OpenClaw JSONL/text logs via filelog receiver |
| [`openclaw_observability_dashboard.json`](./openclaw_observability_dashboard.json) | Pre-built Grafana dashboard with 17 panels covering LLM usage, agent performance, tool calls, security events, traces and logs |

## Background

OpenClaw's built-in OTel module has a known module-isolation bug ([openclaw#5190](https://github.com/openclaw/openclaw/issues/5190)) that prevents it from exporting telemetry correctly. We use the community [otel-observability plugin](https://github.com/henrikrexed/openclaw-observability-plugin) to work around this.

The community plugin supports **Traces** and **Metrics** via OTLP, but **not Logs**. Logs are collected separately from OpenClaw's JSONL/text log files using a dedicated OTel Collector with the `filelog` receiver.

## Architecture

```
OpenClaw (local, port 18789)
  |
  |-- [otel-observability plugin] --traces/metrics--> OTLP HTTP :4318 --+
  |                                                                      |
  |-- [JSONL/text log files] --> Log Collector (filelog) --> OTLP :4317 -+
                                                                         |
                                                                         v
                                                              AI Observe Stack
                                                           +------------------+
                                                           | OTel Gateway     |
                                                           | :4317 (gRPC)     |
                                                           | :4318 (HTTP)     |
                                                           +--------+---------+
                                                                    |
                                                                    v
                                                           +------------------+
                                                           | Apache Doris     |
                                                           | :8040 (Stream)   |
                                                           | :9030 (MySQL)    |
                                                           +------------------+
                                                                    |
                                                                    v
                                                           +------------------+
                                                           | Grafana  :3000   |
                                                           +------------------+
```

## Prerequisites

- Docker and Docker Compose
- AI Observe Stack repository cloned locally (this project)
- OpenClaw installed and running locally (`openclaw gateway start`)
- Node.js >= 22.12.0 (required by OpenClaw)

## Step 1: Start AI Observe Stack

Before proceeding, start the AI Observe Stack which provides the OTel Gateway (telemetry ingestion), Apache Doris (storage), and Grafana (visualization).

```bash
cd <ai-observe-stack-repo>/docker
docker compose up -d
```

Wait for Doris to become healthy (this may take up to 3 minutes on first start):

```bash
docker compose ps
# Verify doris shows "(healthy)" in STATUS column
```

Verify the `otel` database and tables are created:

```bash
docker exec doris mysql -h 127.0.0.1 -P 9030 -uroot -e "USE otel; SHOW TABLES;"
```

Expected tables: `otel_traces`, `otel_logs`, `otel_metrics_gauge`, `otel_metrics_sum`, `otel_metrics_histogram`, etc.

## Step 2: Install the Community OTel Plugin

```bash
mkdir -p ~/.openclaw/plugins
cd ~/.openclaw/plugins
git clone https://github.com/henrikrexed/openclaw-observability-plugin otel-observability
cd otel-observability
npm install
```

## Step 3: Configure OpenClaw

Add the plugin configuration to `~/.openclaw/openclaw.json`. Merge the following into the existing `plugins` section:

```json
{
  "plugins": {
    "load": {
      "paths": ["<HOME>/.openclaw/plugins/otel-observability"]
    },
    "entries": {
      "otel-observability": {
        "enabled": true,
        "config": {
          "endpoint": "http://127.0.0.1:4318",
          "protocol": "http",
          "serviceName": "openclaw",
          "traces": true,
          "metrics": true,
          "logs": false,
          "captureContent": false
        }
      }
    }
  }
}
```

> Replace `<HOME>` with your actual home directory path (e.g., `/Users/yourname`).

Key configuration notes:

| Field | Value | Reason |
|-------|-------|--------|
| `endpoint` | `http://127.0.0.1:4318` | AI Observe Stack's OTel Gateway OTLP HTTP port |
| `logs` | `false` | Community plugin does not support Log OTLP; logs collected via filelog |
| `captureContent` | `false` | Set to `true` to include message content in spans (caution: may contain sensitive data) |

## Step 4: Start the Log Collector

Since the community plugin does not export logs via OTLP, we run a separate OTel Collector to tail OpenClaw's log files and forward them to the AI Observe Stack gateway.

The collector config is provided in this example directory: [`otel-collector-log-config.yaml`](./otel-collector-log-config.yaml).

```bash
docker run -d \
  --name openclaw-log-collector \
  --network docker_aiobs-net \
  -v ~/.openclaw/logs:/openclaw-logs:ro \
  -v $(pwd)/otel-collector-log-config.yaml:/etc/otelcol-contrib/config.yaml:ro \
  otel/opentelemetry-collector-contrib:0.144.0 \
  --config=/etc/otelcol-contrib/config.yaml
```

> **Note:** The container joins `docker_aiobs-net` so it can reach the OTel Gateway at `otel-collector:4317`.

Verify the log collector is running:

```bash
docker logs openclaw-log-collector 2>&1 | tail -5
# Should show "Logs ... log records: N" indicating successful export
```

## Step 5: Restart OpenClaw

Restart the gateway to load the newly installed plugin:

```bash
openclaw gateway restart
```

Verify the plugin loaded successfully:

```bash
grep "otel" ~/.openclaw/logs/gateway.log | tail -10
```

Expected output:

```
[gateway] [otel] Registered before_agent_start hook (via api.on)
[gateway] [otel] Registered tool_result_persist hook (via api.on)
[gateway] [otel] Registered agent_end hook (via api.on)
[gateway] [otel] ✅ Observability pipeline active
[gateway] [otel]   Traces=true Metrics=true Logs=false
[gateway] [otel]   Endpoint=http://127.0.0.1:4318 (http)
```

If you see `Cannot find module '@opentelemetry/api'`, run `npm install` inside the plugin directory.

## Step 6: Generate and Verify Data

Send a message to OpenClaw (via Web UI at `http://127.0.0.1:18789` or WhatsApp) to trigger agent interactions, then verify data in Doris:

```bash
# Check traces
docker exec doris mysql -h 127.0.0.1 -P 9030 -uroot \
  -e "SELECT timestamp, trace_id, span_name, service_name, duration, status_code
      FROM otel.otel_traces ORDER BY timestamp DESC LIMIT 5\G"

# Check logs
docker exec doris mysql -h 127.0.0.1 -P 9030 -uroot \
  -e "SELECT timestamp, body, resource_attributes
      FROM otel.otel_logs ORDER BY timestamp DESC LIMIT 5\G"

# Check metrics
docker exec doris mysql -h 127.0.0.1 -P 9030 -uroot \
  -e "SELECT DISTINCT metric_name
      FROM otel.otel_metrics_sum
      WHERE resource_attributes['service.name'] = 'openclaw';"
```

### Expected Trace Spans

| Span Name | Description |
|-----------|-------------|
| `openclaw.agent.turn` | A full agent interaction turn (includes LLM call + tool execution) |
| `tool.web_search` | Web search tool invocation |
| `tool.web_fetch` | Web fetch tool invocation |
| `tool.*` | Other tool-specific spans |

### Expected Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `openclaw.llm.requests` | Sum | Total LLM API requests |
| `openclaw.llm.tokens.prompt` | Sum | Input tokens consumed |
| `openclaw.llm.tokens.completion` | Sum | Output tokens generated |
| `openclaw.llm.tokens.total` | Sum | Total tokens |
| `openclaw.llm.errors` | Sum | LLM call errors |
| `openclaw.tool.calls` | Sum | Tool invocations |
| `openclaw.tool.errors` | Sum | Tool errors |
| `openclaw.messages.received` | Sum | Messages received |
| `openclaw.messages.sent` | Sum | Messages sent |
| `openclaw.session.resets` | Sum | Session resets |
| `openclaw.security.*` | Sum | Security event counters |

## Visualize in Grafana

Open Grafana at [http://localhost:3000](http://localhost:3000) (default credentials: `admin` / `admin`).

### Import the Dashboard

This example includes a pre-built dashboard: [`openclaw_observability_dashboard.json`](./openclaw_observability_dashboard.json).

Import it via Grafana UI:

1. Go to **Dashboards > New > Import**
2. Click **Upload dashboard JSON file** and select `openclaw_observability_dashboard.json`
3. Select the **Doris** datasource for the `DS_DORIS` input
4. Click **Import**

### Dashboard Panels

The dashboard is organized into 6 sections:

**Overview** — Top-level KPIs at a glance
| Panel | Description |
|-------|-------------|
| LLM Requests | Total LLM API calls |
| Total Tokens | Cumulative token consumption |
| Tool Calls | Total tool invocations |
| Messages Received | Inbound messages to OpenClaw |
| LLM Errors | LLM call failures (red when > 0) |
| Security Events | Security detections (red when > 5) |

**LLM Usage & Token Consumption** — Deep dive into model usage
| Panel | Type | Description |
|-------|------|-------------|
| Token Usage Over Time | Time series | Prompt vs completion tokens trend |
| Token Breakdown by Model | Pie chart | Token share per LLM model (e.g. qwen3.5-plus) |
| LLM Requests Over Time | Bar chart | API call volume trend |

**Agent Performance & Tool Usage** — Operational performance
| Panel | Type | Description |
|-------|------|-------------|
| Agent Turn Duration | Time series | avg/min/max turn latency (ms) from histogram |
| Tool Calls by Type | Pie chart | Distribution across tool types (exec, browser, web_fetch, etc.) |
| Tool Calls Over Time | Stacked area | Per-tool usage trends |

**Traces — Request Timeline** — Distributed tracing
| Panel | Type | Description |
|-------|------|-------------|
| Recent Traces | Table | Latest spans with trace_id, duration, model, token counts, status |
| Span Duration by Type | Bar gauge | Average latency per span type |
| Span Count by Type | Bar chart | Span volume per type |

**Security** — Threat detection monitoring
| Panel | Type | Description |
|-------|------|-------------|
| Prompt Injection Attempts | Stat | Counter (red when > 0) |
| Dangerous Commands | Stat | Counter (red when > 0) |
| Sensitive File Access | Stat | Counter (yellow > 1, red > 5) |
| Tool Errors | Stat | Counter (red when > 0) |
| Security Events Over Time | Time series | All security signal trends |

**Logs** — Gateway log stream
| Panel | Type | Description |
|-------|------|-------------|
| Recent Gateway Logs | Table | Latest 200 log entries with severity, module, source file |

### Ad-hoc Queries

The Doris datasource is pre-configured. You can also query `otel` database tables directly:

```sql
-- Trace timeline for a specific trace
SELECT span_name, timestamp, duration / 1000 AS duration_ms, status_code
FROM otel.otel_traces
WHERE trace_id = '<your-trace-id>'
ORDER BY timestamp;

-- Token usage over time
SELECT DATE_FORMAT(timestamp, '%Y-%m-%d %H:%i') AS ts, metric_name, value
FROM otel.otel_metrics_sum
WHERE resource_attributes['service']['name'] = 'openclaw'
  AND metric_name LIKE 'openclaw.llm.tokens%'
ORDER BY timestamp DESC LIMIT 50;

-- Recent error logs
SELECT timestamp, body, log_attributes
FROM otel.otel_logs
WHERE resource_attributes['service']['name'] = 'openclaw'
  AND CAST(log_attributes['log']['file']['name'] AS VARCHAR) = 'gateway.err.log'
ORDER BY timestamp DESC LIMIT 20;
```

## Cleanup

```bash
# Stop the log collector
docker rm -f openclaw-log-collector

# Stop AI Observe Stack
cd <ai-observe-stack-repo>/docker
docker compose down

# Remove the plugin (optional)
rm -rf ~/.openclaw/plugins/otel-observability
# Then remove the otel-observability entry from ~/.openclaw/openclaw.json
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Plugin fails with `Cannot find module '@opentelemetry/api'` | Run `npm install` in `~/.openclaw/plugins/otel-observability/` |
| No traces in Doris | Verify plugin loaded: `grep "otel" ~/.openclaw/logs/gateway.log` |
| No logs in Doris | Check log collector: `docker logs openclaw-log-collector` |
| OTel Gateway unhealthy | `curl http://127.0.0.1:13133/` should return `{"status":"Server available"}` |
| Doris not healthy | Wait for healthcheck (up to 3 min), check `docker compose ps` |
| `gateway.err.log` regex parse errors | Expected for non-standard lines; `on_error: send` ensures they still get ingested as raw logs |
| Port 3000 conflict (Grafana) | Stop the process on port 3000 or set `GRAFANA_PORT=3001` in `.env` |
