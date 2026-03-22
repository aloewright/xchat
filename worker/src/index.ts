/**
 * xchat Cloudflare Worker
 *
 * Agentic AI chat backend using:
 *   - Cloudflare Workers AI   (@cf/meta/llama-3.1-8b-instruct)
 *   - Composio (@composio/core + @composio/cloudflare) for tool use
 *   - Rube MCP (https://rube.app/mcp) as a second tool provider
 *   - Kinde authentication (PKCE / OAuth 2.0 + JWKS JWT verification)
 *
 * POST /chat              → SSE stream (requires valid Bearer token)
 * GET  /health            → JSON status
 * GET  /auth/login        → Redirects to Kinde auth with PKCE
 * GET  /auth/callback     → Exchanges code for tokens, returns JSON
 * GET  /auth/logout       → Redirects to Kinde logout
 */

import { Composio } from "@composio/core";
import { CloudflareProvider } from "@composio/cloudflare";

// ──────────────────────────────────────────────
// Types
// ──────────────────────────────────────────────

export interface Env {
  ASSETS: Fetcher;
  AI: Ai;
  COMPOSIO_API_KEY: string;
  CORS_ORIGIN?: string;
  MODEL?: string;
  // Rube MCP
  RUBE_MCP_URL?: string;    // defaults to https://rube.app/mcp
  RUBE_API_TOKEN?: string;  // Bearer token for Rube
  RUBE_ENABLED?: string;    // "true" / "false" — flip without redeploying
  // Kinde auth (KINDE_CLIENT_SECRET must be set via `wrangler secret put`)
  KINDE_DOMAIN: string;
  KINDE_CLIENT_ID: string;
  KINDE_CLIENT_SECRET: string;
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
  rubeEnabled?: boolean;
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
const REDIRECT_URI = "https://alex.chat/callback";

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
// Kinde auth helpers
// ──────────────────────────────────────────────

// Module-level JWKS cache — survives across requests within the same isolate.
let jwksCache: { keys: JsonWebKeyWithKid[] } | null = null;

async function getJwks(domain: string): Promise<{ keys: JsonWebKeyWithKid[] }> {
  if (jwksCache) return jwksCache;
  const resp = await fetch(`${domain}/.well-known/jwks`);
  if (!resp.ok) throw new Error(`JWKS fetch failed: ${resp.status}`);
  jwksCache = (await resp.json()) as { keys: JsonWebKeyWithKid[] };
  return jwksCache;
}

/** Verify a Kinde RS256 JWT against the domain's JWKS. Returns true if valid. */
async function verifyJwt(token: string, domain: string): Promise<boolean> {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return false;

    const header = JSON.parse(base64urlToString(parts[0])) as {
      kid?: string;
      alg?: string;
    };
    if (header.alg !== "RS256") return false;

    const jwks = await getJwks(domain);
    const jwk = jwks.keys.find((k) => k.kid === header.kid);
    if (!jwk) return false;

    const cryptoKey = await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"]
    );

    const signingInput = encoder.encode(`${parts[0]}.${parts[1]}`);
    const signature = base64urlToBytes(parts[2]);

    return await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      cryptoKey,
      signature,
      signingInput
    );
  } catch {
    return false;
  }
}

// ── Base64url helpers ────────────────────────────────────────────────────────

function base64urlToString(s: string): string {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  const padded = b64 + "==".slice(0, (4 - (b64.length % 4)) % 4);
  return atob(padded);
}

function base64urlToBytes(s: string): Uint8Array {
  const binary = base64urlToString(s);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function base64urlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

// ── PKCE helpers ─────────────────────────────────────────────────────────────

async function generatePkce(): Promise<{
  codeVerifier: string;
  codeChallenge: string;
}> {
  const random = crypto.getRandomValues(new Uint8Array(32));
  const codeVerifier = base64urlEncode(random);
  const hashBuffer = await crypto.subtle.digest(
    "SHA-256",
    encoder.encode(codeVerifier)
  );
  const codeChallenge = base64urlEncode(new Uint8Array(hashBuffer));
  return { codeVerifier, codeChallenge };
}

function generateState(): string {
  return base64urlEncode(crypto.getRandomValues(new Uint8Array(16)));
}

function getCookie(cookieHeader: string, name: string): string | null {
  const match = cookieHeader.match(
    new RegExp(`(?:^|;\\s*)${name}=([^;]*)`)
  );
  return match ? decodeURIComponent(match[1]) : null;
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
 */
async function fetchRubeTools(url: string, token: string): Promise<McpTool[]> {
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
 */
async function executeRubeTool(
  url: string,
  token: string,
  name: string,
  args: unknown
): Promise<string> {
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

    // ── GET /auth/login ──────────────────────
    // Generates a PKCE pair, stores code_verifier in an httpOnly cookie,
    // and redirects the browser to the Kinde authorization endpoint.
    if (url.pathname === "/auth/login" && request.method === "GET") {
      const { codeVerifier, codeChallenge } = await generatePkce();
      const state = generateState();

      const authUrl = new URL(`${env.KINDE_DOMAIN}/oauth2/auth`);
      authUrl.searchParams.set("response_type", "code");
      authUrl.searchParams.set("client_id", env.KINDE_CLIENT_ID);
      authUrl.searchParams.set("redirect_uri", REDIRECT_URI);
      authUrl.searchParams.set("scope", "openid profile email");
      authUrl.searchParams.set("state", state);
      authUrl.searchParams.set("code_challenge", codeChallenge);
      authUrl.searchParams.set("code_challenge_method", "S256");

      const cookieOpts = "HttpOnly; Secure; SameSite=Lax; Max-Age=600; Path=/";
      const headers = new Headers(cors);
      headers.set("Location", authUrl.toString());
      headers.append(
        "Set-Cookie",
        `kinde_pkce=${encodeURIComponent(codeVerifier)}; ${cookieOpts}`
      );
      headers.append(
        "Set-Cookie",
        `kinde_state=${encodeURIComponent(state)}; ${cookieOpts}`
      );

      return new Response(null, { status: 302, headers });
    }

    // ── GET /auth/callback ───────────────────
    // Receives ?code= (and optional ?state=) from Kinde, reads the
    // code_verifier from cookie (web) or query param (native apps),
    // exchanges the code at Kinde's token endpoint, and returns token JSON.
    if (url.pathname === "/auth/callback" && request.method === "GET") {
      const code = url.searchParams.get("code");
      if (!code) {
        return new Response(
          JSON.stringify({ error: "missing_code" }),
          { status: 400, headers: { ...cors, "Content-Type": "application/json" } }
        );
      }

      // Accept code_verifier from cookie (web PKCE flow) or query param (native)
      const cookieHeader = request.headers.get("Cookie") ?? "";
      const codeVerifier =
        url.searchParams.get("code_verifier") ??
        getCookie(cookieHeader, "kinde_pkce");

      const state = url.searchParams.get("state");
      const savedState = getCookie(cookieHeader, "kinde_state");
      if (state && savedState && state !== savedState) {
        return new Response(
          JSON.stringify({ error: "state_mismatch" }),
          { status: 400, headers: { ...cors, "Content-Type": "application/json" } }
        );
      }

      const tokenParams: Record<string, string> = {
        grant_type: "authorization_code",
        code,
        client_id: env.KINDE_CLIENT_ID,
        client_secret: env.KINDE_CLIENT_SECRET,
        redirect_uri: REDIRECT_URI,
      };
      if (codeVerifier) tokenParams["code_verifier"] = codeVerifier;

      const tokenResp = await fetch(`${env.KINDE_DOMAIN}/oauth2/token`, {
        method: "POST",
        headers: { "Content-Type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams(tokenParams),
      });

      if (!tokenResp.ok) {
        const errText = await tokenResp.text().catch(() => "");
        return new Response(
          JSON.stringify({ error: "token_exchange_failed", detail: errText.slice(0, 200) }),
          { status: 502, headers: { ...cors, "Content-Type": "application/json" } }
        );
      }

      const tokenData = await tokenResp.json();

      // Clear the PKCE cookies now that they've been used
      const clearCookie =
        "HttpOnly; Secure; SameSite=Lax; Max-Age=0; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT";
      const respHeaders = new Headers({ ...cors, "Content-Type": "application/json" });
      respHeaders.append("Set-Cookie", `kinde_pkce=; ${clearCookie}`);
      respHeaders.append("Set-Cookie", `kinde_state=; ${clearCookie}`);

      return new Response(JSON.stringify(tokenData), {
        status: 200,
        headers: respHeaders,
      });
    }

    // ── GET /auth/logout ─────────────────────
    // Redirects to Kinde's logout endpoint.
    if (url.pathname === "/auth/logout" && request.method === "GET") {
      const logoutUrl = new URL(`${env.KINDE_DOMAIN}/logout`);
      logoutUrl.searchParams.set("redirect", "https://alex.chat");
      return new Response(null, {
        status: 302,
        headers: { ...cors, Location: logoutUrl.toString() },
      });
    }

    // ── POST /chat ───────────────────────────
    if (url.pathname === "/chat" && request.method === "POST") {
      // ── Auth guard: require a valid Bearer token ──
      const authHeader = request.headers.get("Authorization") ?? "";
      if (!authHeader.startsWith("Bearer ")) {
        return new Response(
          JSON.stringify({ error: "unauthorized" }),
          { status: 401, headers: { ...cors, "Content-Type": "application/json" } }
        );
      }
      const bearerToken = authHeader.slice(7).trim();
      const tokenValid = await verifyJwt(bearerToken, env.KINDE_DOMAIN);
      if (!tokenValid) {
        return new Response(
          JSON.stringify({ error: "invalid_token" }),
          { status: 401, headers: { ...cors, "Content-Type": "application/json" } }
        );
      }

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

    return env.ASSETS.fetch(request);
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
  const rubeServerEnabled = env.RUBE_ENABLED === "true";
  const rubeMcpUrl = env.RUBE_MCP_URL ?? DEFAULT_RUBE_URL;
  const rubeToken = env.RUBE_API_TOKEN ?? "";
  const rubeActive = rubeServerEnabled && clientRubeEnabled && rubeToken !== "";

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
    const aiResponse = await runAI({
      messages,
      ...(toolsArray.length > 0 && { tools: toolsArray }),
    });

    if (aiResponse.tool_calls && aiResponse.tool_calls.length > 0) {
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

        await writeSse(writer, "tool_call", { name: tc.name, arguments: args });

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

        await writeSse(writer, "tool_result", {
          name: tc.name,
          result: resultParsed,
        });

        messages.push({
          role: "tool",
          content: resultStr,
          tool_call_id: tc.name,
        });
      }

      continue;
    }

    // ── No more tool calls → stream final reply ──
    const finalText = aiResponse.response ?? "";

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
      const words = finalText.split(/(\s+)/);
      for (const chunk of words) {
        if (chunk) await writeSse(writer, "token", { content: chunk });
      }
    }

    await writeSse(writer, "done", { content: finalText });
    await writer.close();
    return;
  }

  await writeSse(writer, "error", {
    message: "Max tool iterations reached without a final response.",
  });
  await writer.close();
}
