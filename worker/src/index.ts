/**
 * xchat Cloudflare Worker
 *
 * Agentic AI chat backend using:
 *   - Cloudflare Workers AI   (@cf/meta/llama-3.1-8b-instruct)
 *   - Composio (@composio/core + @composio/cloudflare) for tool use
 *   - Rube MCP (https://rube.app/mcp) as a second tool provider
 *
 * POST /chat  → SSE stream with token / tool_call / tool_result / done / error events
 * GET  /health → JSON status
 */

import { Composio } from "@composio/core";
import { CloudflareProvider } from "@composio/cloudflare";

// ──────────────────────────────────────────────
// Types
// ──────────────────────────────────────────────

export interface Env {
  AI: Ai;
  COMPOSIO_API_KEY: string;
  CORS_ORIGIN?: string;
  MODEL?: string;
  // Rube MCP
  RUBE_MCP_URL?: string;   // defaults to https://rube.app/mcp
  RUBE_API_TOKEN?: string; // Bearer token for Rube
  RUBE_ENABLED?: string;   // "true" / "false" — flip without redeploying
}

interface ChatMessage {
  role: "user" | "assistant" | "system" | "tool";
  content: string;
  tool_call_id?: string;
  tool_calls?: Array<{ name: string; arguments: string }>;
}

interface ChatRequest {
  messages: ChatMessage[];
  userId?: string;
  model?: string;
  toolkits?: string[];
  rubeEnabled?: boolean; // client-side toggle sent in the request body
}

type SSEEventName =
  | "token"
  | "tool_call"
  | "tool_result"
  | "warning"
  | "done"
  | "error";

interface SSEPayload {
  content?: string;
  name?: string;
  arguments?: unknown;
  result?: unknown;
  message?: string;
}

// ── Rube MCP wire types ──────────────────────────────────────────────────────

interface McpTool {
  name: string;
  description?: string;
  inputSchema?: {
    type: string;
    properties?: Record<string, unknown>;
    required?: string[];
    [key: string]: unknown;
  };
}

interface McpToolsListResult {
  tools: McpTool[];
  nextCursor?: string;
}

interface McpCallResultContent {
  type: string;
  text?: string;
}

interface McpCallResult {
  content?: McpCallResultContent[];
  isError?: boolean;
}

interface McpJsonRpcResponse {
  jsonrpc: "2.0";
  id: number;
  result?: unknown;
  error?: { code: number; message: string };
}

// ──────────────────────────────────────────────
// Constants
// ──────────────────────────────────────────────

const DEFAULT_MODEL = "@cf/meta/llama-3.1-8b-instruct";
const DEFAULT_USER_ID = "default";
const MAX_TOOL_ITERATIONS = 6;
const DEFAULT_TOOLKITS = ["hackernews"];
const DEFAULT_RUBE_URL = "https://rube.app/mcp";

// ──────────────────────────────────────────────
// SSE helpers
// ──────────────────────────────────────────────

const encoder = new TextEncoder();

function writeSse(
  writer: WritableStreamDefaultWriter<Uint8Array>,
  event: SSEEventName,
  data: SSEPayload
): Promise<void> {
  const payload = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  return writer.write(encoder.encode(payload));
}

function corsHeaders(origin: string): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Max-Age": "86400",
  };
}

// ──────────────────────────────────────────────
// Rube MCP helpers
// ──────────────────────────────────────────────

/** Convert an MCP tool definition to the Workers AI tool format. */
function mcpToolToAiTool(tool: McpTool): Record<string, unknown> {
  return {
    name: tool.name,
    description: tool.description ?? "",
    parameters: tool.inputSchema ?? { type: "object", properties: {} },
  };
}

/**
 * POST a JSON-RPC 2.0 request to the Rube MCP endpoint.
 * Handles both plain JSON and text/event-stream responses.
 */
async function rubeMcpPost(
  url: string,
  token: string,
  body: unknown
): Promise<McpJsonRpcResponse> {
  const resp = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json, text/event-stream",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(body),
  });

  if (!resp.ok) {
    const text = await resp.text().catch(() => "");
    throw new Error(`Rube MCP HTTP ${resp.status}: ${text.slice(0, 200)}`);
  }

  const ct = resp.headers.get("content-type") ?? "";

  if (ct.includes("text/event-stream")) {
    // Drain the SSE stream and return the last complete JSON-RPC message.
    const responseBody = resp.body;
    if (!responseBody) throw new Error("Empty body in Rube MCP SSE response");

    const reader = responseBody.getReader();
    const dec = new TextDecoder();
    let buf = "";
    let last: McpJsonRpcResponse | null = null;

    outer: while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      const parts = buf.split("\n\n");
      buf = parts.pop() ?? "";
      for (const part of parts) {
        for (const line of part.split("\n")) {
          if (!line.startsWith("data: ")) continue;
          const raw = line.slice(6).trim();
          if (raw === "[DONE]") { break outer; }
          try {
            last = JSON.parse(raw) as McpJsonRpcResponse;
          } catch { /* ignore malformed */ }
        }
      }
    }

    if (!last) throw new Error("No JSON-RPC message received from Rube MCP SSE stream");
    return last;
  }

  return resp.json() as Promise<McpJsonRpcResponse>;
}

/**
 * Run the MCP initialize + tools/list handshake and return the tool list.
 * Each HTTP call to the Rube endpoint is independent (stateless transport).
 */
async function fetchRubeTools(url: string, token: string): Promise<McpTool[]> {
  // Step 1: initialize
  await rubeMcpPost(url, token, {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "xchat", version: "1.0" },
    },
  });

  // Step 2: list tools
  const listResp = await rubeMcpPost(url, token, {
    jsonrpc: "2.0",
    id: 2,
    method: "tools/list",
    params: {},
  });

  if (listResp.error) {
    throw new Error(`Rube tools/list error: ${listResp.error.message}`);
  }

  const result = listResp.result as McpToolsListResult | undefined;
  return result?.tools ?? [];
}

/**
 * Execute a single Rube tool via MCP tools/call.
 * Re-initializes the session (HTTP stateless) before each call.
 */
async function executeRubeTool(
  url: string,
  token: string,
  name: string,
  args: unknown
): Promise<string> {
  // Re-initialize (streamable HTTP transport is stateless per-request)
  await rubeMcpPost(url, token, {
    jsonrpc: "2.0",
    id: 1,
    method: "initialize",
    params: {
      protocolVersion: "2024-11-05",
      capabilities: {},
      clientInfo: { name: "xchat", version: "1.0" },
    },
  });

  const resp = await rubeMcpPost(url, token, {
    jsonrpc: "2.0",
    id: 3,
    method: "tools/call",
    params: { name, arguments: args },
  });

  if (resp.error) {
    throw new Error(`Rube tool "${name}" error: ${resp.error.message}`);
  }

  const result = resp.result as McpCallResult | undefined;
  if (result?.content && result.content.length > 0) {
    const texts = result.content
      .filter((c) => c.type === "text" && typeof c.text === "string")
      .map((c) => c.text as string);
    if (texts.length > 0) return texts.join("\n");
  }
  return JSON.stringify(resp.result ?? {});
}

// ──────────────────────────────────────────────
// Worker entry-point
// ──────────────────────────────────────────────

export default {
  async fetch(
    request: Request,
    env: Env,
    ctx: ExecutionContext
  ): Promise<Response> {
    const origin = env.CORS_ORIGIN ?? "*";
    const cors = corsHeaders(origin);

    // Pre-flight
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: cors });
    }

    const url = new URL(request.url);

    // ── GET /health ──────────────────────────
    if (url.pathname === "/health") {
      return Response.json(
        {
          status: "ok",
          model: env.MODEL ?? DEFAULT_MODEL,
          rubeEnabled: env.RUBE_ENABLED === "true",
          ts: Date.now(),
        },
        { headers: cors }
      );
    }

    // ── POST /chat ───────────────────────────
    if (url.pathname === "/chat" && request.method === "POST") {
      let body: ChatRequest;
      try {
        body = (await request.json()) as ChatRequest;
      } catch {
        return new Response("Invalid JSON body", {
          status: 400,
          headers: cors,
        });
      }

      if (!body.messages || !Array.isArray(body.messages)) {
        return new Response("`messages` array is required", {
          status: 400,
          headers: cors,
        });
      }

      const { readable, writable } = new TransformStream<
        Uint8Array,
        Uint8Array
      >();
      const writer = writable.getWriter();

      ctx.waitUntil(
        agenticLoop(writer, env, body).catch(async (err) => {
          await writeSse(writer, "error", { message: String(err) }).catch(
            () => {}
          );
          await writer.close().catch(() => {});
        })
      );

      return new Response(readable, {
        headers: {
          ...cors,
          "Content-Type": "text/event-stream; charset=utf-8",
          "Cache-Control": "no-cache, no-store",
          "X-Accel-Buffering": "no",
        },
      });
    }

    return new Response("Not Found", { status: 404, headers: cors });
  },
};

// ──────────────────────────────────────────────
// Agentic loop
// ──────────────────────────────────────────────

async function agenticLoop(
  writer: WritableStreamDefaultWriter<Uint8Array>,
  env: Env,
  req: ChatRequest
): Promise<void> {
  const {
    messages: rawMessages,
    userId = DEFAULT_USER_ID,
    model = env.MODEL ?? DEFAULT_MODEL,
    toolkits = DEFAULT_TOOLKITS,
    rubeEnabled: clientRubeEnabled = false,
  } = req;

  // ── 1. Build Composio + load tools ──────────
  const composio = new Composio({
    apiKey: env.COMPOSIO_API_KEY,
    provider: new CloudflareProvider(),
  });

  let toolsArray: unknown[] = [];

  if (env.COMPOSIO_API_KEY) {
    try {
      const toolCollection = (await composio.tools.get(userId, {
        toolkits,
        limit: 10,
      })) as Record<string, unknown>;
      toolsArray = Object.values(toolCollection);
    } catch (err) {
      await writeSse(writer, "warning", {
        message: `Composio tools unavailable (${(err as Error).message}). Continuing without Composio.`,
      });
    }
  } else {
    await writeSse(writer, "warning", {
      message: "COMPOSIO_API_KEY not set – Composio tools disabled.",
    });
  }

  // ── 2. Optionally load Rube tools ────────────
  //
  // Two-level gate:
  //   • RUBE_ENABLED env var  — server-side switch (flip via wrangler vars/secret, no redeploy)
  //   • clientRubeEnabled     — per-request toggle sent by the client UI
  //
  const rubeServerEnabled = env.RUBE_ENABLED === "true";
  const rubeMcpUrl = env.RUBE_MCP_URL ?? DEFAULT_RUBE_URL;
  const rubeToken = env.RUBE_API_TOKEN ?? "";
  const rubeActive = rubeServerEnabled && clientRubeEnabled && rubeToken !== "";

  // Track which tool names belong to Rube so we can route tool calls correctly.
  const rubeToolNames = new Set<string>();

  if (rubeActive) {
    try {
      const rubeTools = await fetchRubeTools(rubeMcpUrl, rubeToken);
      for (const t of rubeTools) {
        rubeToolNames.add(t.name);
        toolsArray.push(mcpToolToAiTool(t));
      }
      if (rubeTools.length === 0) {
        await writeSse(writer, "warning", {
          message: "Rube MCP connected but returned no tools.",
        });
      }
    } catch (err) {
      await writeSse(writer, "warning", {
        message: `Rube tools unavailable (${(err as Error).message}). Continuing without Rube.`,
      });
    }
  }

  // ── 3. Build message array ───────────────────
  const messages: ChatMessage[] = [];

  // Inject system prompt if none present
  if (!rawMessages.some((m) => m.role === "system")) {
    messages.push({
      role: "system",
      content:
        "You are xchat, a helpful AI assistant with access to tools. " +
        "Use tools whenever they can improve the accuracy of your answer. " +
        "Be concise, clear, and thoughtful.",
    });
  }

  messages.push(...rawMessages);

  // Typed helper – avoids repeating the cast at each call site.
  // Workers AI binding types are strict about model names; using `any`
  // here lets us pass a runtime string while keeping the rest of the
  // file fully typed.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const runAI = (inputs: Record<string, unknown>): Promise<{
    response?: string;
    tool_calls?: Array<{ name: string; arguments: string | object }>;
  }> =>
    (env.AI as unknown as { run: (...a: unknown[]) => unknown }).run(model, inputs) as Promise<{
      response?: string;
      tool_calls?: Array<{ name: string; arguments: string | object }>;
    }>;

  // ── 4. Agentic tool-calling loop ─────────────
  for (let iter = 0; iter < MAX_TOOL_ITERATIONS; iter++) {
    // Run the model (non-streaming so we can inspect tool_calls)
    const aiResponse = await runAI({
      messages,
      ...(toolsArray.length > 0 && { tools: toolsArray }),
    });

    // ── Tool calls? Execute them and continue ──
    if (aiResponse.tool_calls && aiResponse.tool_calls.length > 0) {
      // Add assistant message that requested tool calls
      messages.push({
        role: "assistant",
        content: aiResponse.response ?? "",
        tool_calls: aiResponse.tool_calls.map((tc) => ({
          name: tc.name,
          arguments:
            typeof tc.arguments === "string"
              ? tc.arguments
              : JSON.stringify(tc.arguments),
        })),
      });

      for (const tc of aiResponse.tool_calls) {
        const args =
          typeof tc.arguments === "string"
            ? (() => {
                try {
                  return JSON.parse(tc.arguments);
                } catch {
                  return tc.arguments;
                }
              })()
            : tc.arguments;

        // Emit tool_call event to client
        await writeSse(writer, "tool_call", { name: tc.name, arguments: args });

        // Route execution: Rube tools → Rube MCP, everything else → Composio
        let resultStr: string;
        try {
          if (rubeToolNames.has(tc.name)) {
            resultStr = await executeRubeTool(
              rubeMcpUrl,
              rubeToken,
              tc.name,
              args
            );
          } else {
            resultStr = await composio.provider.executeToolCall(
              userId,
              { name: tc.name, arguments: tc.arguments },
              {}
            );
          }
        } catch (err) {
          resultStr = JSON.stringify({ error: String(err) });
        }

        let resultParsed: unknown;
        try {
          resultParsed = JSON.parse(resultStr);
        } catch {
          resultParsed = resultStr;
        }

        // Emit tool_result event to client
        await writeSse(writer, "tool_result", {
          name: tc.name,
          result: resultParsed,
        });

        // Append tool result to message history
        messages.push({
          role: "tool",
          content: resultStr,
          tool_call_id: tc.name,
        });
      }

      // Next iteration will see tool results and produce a reply
      continue;
    }

    // ── No more tool calls → stream final reply ──
    const finalText = aiResponse.response ?? "";

    // Stream the final answer using Workers AI native streaming
    try {
      const stream = (await (env.AI as unknown as { run: (...a: unknown[]) => unknown }).run(
        model,
        { messages, stream: true }
      )) as ReadableStream<Uint8Array>;

      const reader = stream.getReader();
      const dec = new TextDecoder();
      let buffer = "";

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        buffer += dec.decode(value, { stream: true });

        // SSE lines may be batched – process all complete events
        const parts = buffer.split("\n\n");
        buffer = parts.pop() ?? "";

        for (const part of parts) {
          for (const line of part.split("\n")) {
            if (!line.startsWith("data: ")) continue;
            const raw = line.slice(6).trim();
            if (raw === "[DONE]") continue;
            try {
              const parsed = JSON.parse(raw) as { response?: string };
              if (parsed.response) {
                await writeSse(writer, "token", { content: parsed.response });
              }
            } catch {
              /* ignore malformed chunks */
            }
          }
        }
      }
    } catch {
      // Fallback: emit the pre-fetched text word-by-word
      const words = finalText.split(/(\s+)/);
      for (const chunk of words) {
        if (chunk) await writeSse(writer, "token", { content: chunk });
      }
    }

    await writeSse(writer, "done", { content: finalText });
    await writer.close();
    return;
  }

  // Exceeded max iterations without a final text response
  await writeSse(writer, "error", {
    message: "Max tool iterations reached without a final response.",
  });
  await writer.close();
}
