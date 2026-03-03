# OpenClaw 可观测接入指南 — AI Observe Stack

本指南介绍如何使用 AI Observe Stack 对本地运行的 [OpenClaw](https://openclaw.dev) 实例实现全链路可观测（Traces、Metrics、Logs）。

## 目录提供内容

| 文件 | 说明 |
|------|------|
| [`otel-collector-log-config.yaml`](./otel-collector-log-config.yaml) | OTel Collector 配置，通过 filelog receiver 采集 OpenClaw 的 JSONL/文本日志 |
| [`openclaw_observability_dashboard.json`](./openclaw_observability_dashboard.json) | Grafana 预置 Dashboard，包含 17 个面板，覆盖 LLM 用量、Agent 性能、工具调用、安全事件、链路追踪和日志 |

## 背景

OpenClaw 自带的 OTel 模块存在模块隔离 Bug（[openclaw#5190](https://github.com/openclaw/openclaw/issues/5190)），无法正常导出遥测数据。我们使用社区 [otel-observability 插件](https://github.com/henrikrexed/openclaw-observability-plugin) 绕过此问题。

社区插件支持通过 OTLP 导出 **Traces** 和 **Metrics**，但**不支持 Logs**。日志通过独立的 OTel Collector 以 `filelog` receiver 方式从 OpenClaw 的 JSONL/文本日志文件中采集。

## 架构

```
OpenClaw（本地，端口 18789）
  |
  |-- [otel-observability 插件] --traces/metrics--> OTLP HTTP :4318 --+
  |                                                                     |
  |-- [JSONL/文本日志文件] --> Log Collector (filelog) --> OTLP :4317 --+
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

## 前置条件

- Docker 和 Docker Compose
- AI Observe Stack 仓库已克隆到本地（即本项目）
- OpenClaw 已安装并在本地运行（`openclaw gateway start`）
- Node.js >= 22.12.0（OpenClaw 要求）

## 第一步：启动 AI Observe Stack

在执行后续步骤之前，需要先启动 AI Observe Stack，它提供 OTel Gateway（接收遥测数据）、Apache Doris（存储）和 Grafana（可视化）。

```bash
cd <ai-observe-stack 仓库>/docker
docker compose up -d
```

等待 Doris 健康就绪（首次启动可能需要 3 分钟）：

```bash
docker compose ps
# 确认 doris 的 STATUS 列显示 "(healthy)"
```

验证 `otel` 数据库和表已创建：

```bash
docker exec doris mysql -h 127.0.0.1 -P 9030 -uroot -e "USE otel; SHOW TABLES;"
```

预期表：`otel_traces`、`otel_logs`、`otel_metrics_gauge`、`otel_metrics_sum`、`otel_metrics_histogram` 等。

## 第二步：安装社区 OTel 插件

```bash
mkdir -p ~/.openclaw/plugins
cd ~/.openclaw/plugins
git clone https://github.com/henrikrexed/openclaw-observability-plugin otel-observability
cd otel-observability
npm install
```

## 第三步：配置 OpenClaw

在 `~/.openclaw/openclaw.json` 的 `plugins` 部分中合并以下配置：

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

> 将 `<HOME>` 替换为你的实际用户目录路径（如 `/Users/yourname`）。

配置说明：

| 字段 | 值 | 说明 |
|------|-----|------|
| `endpoint` | `http://127.0.0.1:4318` | AI Observe Stack 的 OTel Gateway OTLP HTTP 端口 |
| `logs` | `false` | 社区插件不支持 Log OTLP 导出，日志通过 filelog 采集 |
| `captureContent` | `false` | 设为 `true` 可在 Span 中包含消息内容（注意：可能包含敏感数据） |

## 第四步：启动日志采集 Collector

由于社区插件不导出日志，我们需要运行一个独立的 OTel Collector 来 tail OpenClaw 的日志文件并转发到 AI Observe Stack 的 Gateway。

Collector 配置文件已包含在本目录中：[`otel-collector-log-config.yaml`](./otel-collector-log-config.yaml)。

```bash
docker run -d \
  --name openclaw-log-collector \
  --network docker_aiobs-net \
  -v ~/.openclaw/logs:/openclaw-logs:ro \
  -v $(pwd)/otel-collector-log-config.yaml:/etc/otelcol-contrib/config.yaml:ro \
  otel/opentelemetry-collector-contrib:0.144.0 \
  --config=/etc/otelcol-contrib/config.yaml
```

> **注意：** 容器加入了 `docker_aiobs-net` 网络，以便通过 `otel-collector:4317` 访问 OTel Gateway。

验证 Log Collector 是否运行正常：

```bash
docker logs openclaw-log-collector 2>&1 | tail -5
# 应看到 "Logs ... log records: N" 表示成功导出
```

## 第五步：重启 OpenClaw

重启 Gateway 以加载新安装的插件：

```bash
openclaw gateway restart
```

验证插件是否加载成功：

```bash
grep "otel" ~/.openclaw/logs/gateway.log | tail -10
```

预期输出：

```
[gateway] [otel] Registered before_agent_start hook (via api.on)
[gateway] [otel] Registered tool_result_persist hook (via api.on)
[gateway] [otel] Registered agent_end hook (via api.on)
[gateway] [otel] ✅ Observability pipeline active
[gateway] [otel]   Traces=true Metrics=true Logs=false
[gateway] [otel]   Endpoint=http://127.0.0.1:4318 (http)
```

如果看到 `Cannot find module '@opentelemetry/api'`，请在插件目录下执行 `npm install`。

## 第六步：生成数据并验证

在 OpenClaw 中发送一条消息（通过 Web UI `http://127.0.0.1:18789` 或 WhatsApp）触发 Agent 交互，然后在 Doris 中验证数据：

```bash
# 检查 Traces
docker exec doris mysql -h 127.0.0.1 -P 9030 -uroot \
  -e "SELECT timestamp, trace_id, span_name, service_name, duration, status_code
      FROM otel.otel_traces ORDER BY timestamp DESC LIMIT 5\G"

# 检查 Logs
docker exec doris mysql -h 127.0.0.1 -P 9030 -uroot \
  -e "SELECT timestamp, body, resource_attributes
      FROM otel.otel_logs ORDER BY timestamp DESC LIMIT 5\G"

# 检查 Metrics
docker exec doris mysql -h 127.0.0.1 -P 9030 -uroot \
  -e "SELECT DISTINCT metric_name
      FROM otel.otel_metrics_sum
      WHERE resource_attributes['service.name'] = 'openclaw';"
```

### Trace Span 类型说明

| Span 名称 | 说明 |
|-----------|------|
| `openclaw.request` | 根 Span — 一次完整的用户请求 |
| `openclaw.agent.turn` | Agent 交互回合（包含 LLM 调用 + 工具执行） |
| `tool.exec` | shell 命令执行 |
| `tool.browser` | 浏览器控制操作 |
| `tool.web_search` | 网页搜索 |
| `tool.web_fetch` | 网页抓取 |
| `tool.*` | 其他工具的 Span |

### Metrics 指标说明

**LLM 指标（Sum 类型，累计计数器）**

| 指标名 | 说明 | 属性维度 |
|--------|------|----------|
| `openclaw.llm.requests` | LLM API 调用次数 | `gen_ai.response.model`, `openclaw.agent.id` |
| `openclaw.llm.tokens.prompt` | 输入 Token 数 | `gen_ai.response.model` |
| `openclaw.llm.tokens.completion` | 输出 Token 数 | `gen_ai.response.model` |
| `openclaw.llm.tokens.total` | 总 Token 数 | `gen_ai.response.model` |
| `openclaw.llm.errors` | LLM 调用错误数 | `gen_ai.response.model` |

**工具指标**

| 指标名 | 说明 | 属性维度 |
|--------|------|----------|
| `openclaw.tool.calls` | 工具调用次数 | `tool.name`, `session.key` |
| `openclaw.tool.errors` | 工具执行错误数 | `tool.name` |

**消息 & 会话指标**

| 指标名 | 说明 | 属性维度 |
|--------|------|----------|
| `openclaw.messages.received` | 收到的消息数 | `openclaw.message.channel` |
| `openclaw.messages.sent` | 发出的消息数 | — |
| `openclaw.session.resets` | 会话重置次数 | `command.source` |

**安全指标**

| 指标名 | 说明 | 属性维度 |
|--------|------|----------|
| `openclaw.security.events` | 安全事件总数 | `detection`, `severity` |
| `openclaw.security.prompt_injection` | 提示注入检测次数 | `pattern_count` |
| `openclaw.security.dangerous_command` | 危险命令检测次数 | `command_type` |
| `openclaw.security.sensitive_file_access` | 敏感文件访问检测次数 | `file_pattern` |

**Agent 性能（Histogram 类型）**

| 指标名 | 单位 | 说明 | 属性维度 |
|--------|------|------|----------|
| `openclaw.agent.turn_duration` | ms | Agent 回合耗时分布 | `gen_ai.response.model`, `openclaw.agent.id` |

## 在 Grafana 中可视化

打开 Grafana：[http://localhost:3000](http://localhost:3000)（默认账号密码：`admin` / `admin`）。

### 导入 Dashboard

本目录提供了预置 Dashboard：[`openclaw_observability_dashboard.json`](./openclaw_observability_dashboard.json)。

通过 Grafana UI 导入：

1. 进入 **Dashboards > New > Import**
2. 点击 **Upload dashboard JSON file**，选择 `openclaw_observability_dashboard.json`
3. 在 `DS_DORIS` 输入框中选择 **Doris** 数据源
4. 点击 **Import**

### Dashboard 面板一览

Dashboard 分为 6 个区块，共 17 个面板：

**概览（Overview）** — 核心 KPI 一目了然

| 面板 | 说明 |
|------|------|
| LLM Requests | LLM API 总调用次数 |
| Total Tokens | 累计 Token 消耗量 |
| Tool Calls | 工具总调用次数 |
| Messages Received | 收到的消息总数 |
| LLM Errors | LLM 调用失败数（> 0 变红） |
| Security Events | 安全事件总数（> 5 变红） |

**LLM 用量与 Token 消耗（LLM Usage & Token Consumption）** — 模型使用深度分析

| 面板 | 类型 | 说明 |
|------|------|------|
| Token Usage Over Time | 时序图 | Prompt Token vs Completion Token 趋势 |
| Token Breakdown by Model | 饼图 | 按模型（如 qwen3.5-plus）的 Token 占比 |
| LLM Requests Over Time | 柱状图 | API 调用量趋势 |

**Agent 性能与工具使用（Agent Performance & Tool Usage）** — 运行效率监控

| 面板 | 类型 | 说明 |
|------|------|------|
| Agent Turn Duration | 时序图 | Agent 回合耗时（avg/min/max，单位 ms） |
| Tool Calls by Type | 饼图 | 各工具类型（exec、browser、web_fetch 等）调用分布 |
| Tool Calls Over Time | 堆叠面积图 | 按工具分类的使用趋势 |

**链路追踪（Traces — Request Timeline）** — 分布式追踪

| 面板 | 类型 | 说明 |
|------|------|------|
| Recent Traces | 表格 | 最新 Span 列表，含 trace_id、耗时、模型、Token 数、状态 |
| Span Duration by Type | 条形仪表图 | 各 Span 类型平均耗时 |
| Span Count by Type | 条形图 | 各 Span 类型数量 |

**安全（Security）** — 威胁检测监控

| 面板 | 类型 | 说明 |
|------|------|------|
| Prompt Injection Attempts | 数值卡片 | 提示注入次数（> 0 变红） |
| Dangerous Commands | 数值卡片 | 危险命令次数（> 0 变红） |
| Sensitive File Access | 数值卡片 | 敏感文件访问次数（> 1 变黄，> 5 变红） |
| Tool Errors | 数值卡片 | 工具错误次数（> 0 变红） |
| Security Events Over Time | 时序图 | 所有安全信号趋势线 |

**日志（Logs）** — Gateway 日志流

| 面板 | 类型 | 说明 |
|------|------|------|
| Recent Gateway Logs | 表格 | 最近 200 条日志，含 severity、module、来源文件 |

### 自定义查询

Doris 数据源已预配置，你也可以直接在 Grafana Explore 中执行 SQL 查询：

```sql
-- 查看某条 Trace 的完整 Span 时间线
SELECT span_name, timestamp, duration / 1000 AS duration_ms, status_code
FROM otel.otel_traces
WHERE trace_id = '<your-trace-id>'
ORDER BY timestamp;

-- Token 使用趋势
SELECT DATE_FORMAT(timestamp, '%Y-%m-%d %H:%i') AS ts, metric_name, value
FROM otel.otel_metrics_sum
WHERE resource_attributes['service']['name'] = 'openclaw'
  AND metric_name LIKE 'openclaw.llm.tokens%'
ORDER BY timestamp DESC LIMIT 50;

-- 最近的错误日志
SELECT timestamp, body, log_attributes
FROM otel.otel_logs
WHERE resource_attributes['service']['name'] = 'openclaw'
  AND CAST(log_attributes['log']['file']['name'] AS VARCHAR) = 'gateway.err.log'
ORDER BY timestamp DESC LIMIT 20;
```

## 清理

```bash
# 停止日志采集 Collector
docker rm -f openclaw-log-collector

# 停止 AI Observe Stack
cd <ai-observe-stack 仓库>/docker
docker compose down

# 移除插件（可选）
rm -rf ~/.openclaw/plugins/otel-observability
# 然后从 ~/.openclaw/openclaw.json 中移除 otel-observability 相关配置
```

## 常见问题

| 问题 | 解决方案 |
|------|----------|
| 插件报错 `Cannot find module '@opentelemetry/api'` | 在 `~/.openclaw/plugins/otel-observability/` 下执行 `npm install` |
| Doris 中没有 Traces 数据 | 检查插件是否加载：`grep "otel" ~/.openclaw/logs/gateway.log` |
| Doris 中没有 Logs 数据 | 检查日志采集器：`docker logs openclaw-log-collector` |
| OTel Gateway 不健康 | `curl http://127.0.0.1:13133/` 应返回 `{"status":"Server available"}` |
| Doris 未就绪 | 等待 healthcheck 通过（最多 3 分钟），执行 `docker compose ps` 查看状态 |
| `gateway.err.log` 出现 regex 解析错误 | 预期行为，非标准格式的日志行会以原始文本写入，不影响数据完整性 |
| Grafana 端口 3000 冲突 | 停止占用 3000 端口的进程，或在 `.env` 中设置 `GRAFANA_PORT=3001` |
