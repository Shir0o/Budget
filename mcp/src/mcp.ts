// MCP over Streamable HTTP, the plain-JSON way: every request is one POST
// answered with one JSON body, and nothing is streamed or kept between
// requests. GET and DELETE get 405, so clients don't hold a stream open or
// reconnect in a loop.
import { callTool, listTools } from "./budget";
import { type Env, type GrantProps, WRITE_SCOPE } from "./env";
import { driveAccessToken } from "./google";

const KNOWN_VERSIONS = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

const INSTRUCTIONS =
  "Access to one budget through its encrypted Google Drive sync, as of the " +
  "last sync from the phone or the Mac. Every string is redacted: card and " +
  "account numbers never leave, and account names carry at most a last-4 " +
  "suffix. Nothing here deletes anything. Only a person marks a line " +
  "Reviewed in the app, except mark_imported_reviewed, if offered, which " +
  "does it for lines a one-time import brought in. Each write is one change with actor mcp:<client>, " +
  "revertable with revert_change or from Change History.";

type Id = string | number | null;
interface RpcMessage {
  jsonrpc?: string;
  id?: Id;
  method?: string;
  params?: Record<string, unknown>;
}

export type McpContext = ExecutionContext & {
  props?: GrantProps;
  auth?: { scope?: string[] };
};

export async function handleMcp(request: Request, env: Env, ctx: McpContext): Promise<Response> {
  if (request.method !== "POST") {
    return new Response("Use POST.", { status: 405, headers: { allow: "POST" } });
  }
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return json(rpcError(null, -32700, "Parse error"));
  }
  const batch = Array.isArray(body);
  const messages = (batch ? body : [body]) as RpcMessage[];
  const answers = [];
  for (const message of messages) {
    const answer = await handle(message, env, ctx);
    if (answer) answers.push(answer);
  }
  if (answers.length === 0) return new Response(null, { status: 202 });
  return json(batch ? answers : answers[0]);
}

async function handle(message: RpcMessage, env: Env, ctx: McpContext) {
  if (!message || typeof message !== "object" || typeof message.method !== "string") {
    return rpcError(message?.id ?? null, -32600, "Invalid request");
  }
  // A notification gets no answer.
  if (message.id === undefined) return null;
  const id = message.id;
  try {
    switch (message.method) {
      case "initialize": {
        const asked = String(message.params?.protocolVersion ?? "");
        return result(id, {
          protocolVersion: KNOWN_VERSIONS.includes(asked) ? asked : KNOWN_VERSIONS[0],
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "budget-cloud-mcp", version: "1.0.0" },
          instructions: INSTRUCTIONS,
        });
      }
      case "ping":
        return result(id, {});
      case "tools/list":
        return result(id, { tools: await listTools(env) });
      case "tools/call":
        return result(id, await call(message.params ?? {}, env, ctx));
      default:
        return rpcError(id, -32601, `Method not found: ${message.method}`);
    }
  } catch (error) {
    console.error("budget-mcp:", error instanceof Error ? error.message : "error");
    return rpcError(id, -32603, error instanceof Error ? error.message : "Internal error");
  }
}

async function call(params: Record<string, unknown>, env: Env, ctx: McpContext) {
  const name = String(params.name ?? "");
  const args = (params.arguments ?? {}) as Record<string, unknown>;
  const tools = await listTools(env);
  const tool = tools.find((t) => t.name === name);
  // A write needs the grant's write scope too, so a connection approved
  // read-only stays read-only whatever the server allows.
  if (tool && !tool.annotations.readOnlyHint && !(ctx.auth?.scope ?? []).includes(WRITE_SCOPE)) {
    return textResult(JSON.stringify({ error: "This connection was approved read-only." }), true);
  }
  const token = await driveAccessToken(env);
  const answer = await callTool(env, token, name, args, ctx.props?.clientName ?? "");
  return textResult(answer.text, answer.isError);
}

function textResult(text: string, isError: boolean) {
  return { content: [{ type: "text", text }], ...(isError ? { isError: true } : {}) };
}

function result(id: Id, value: unknown) {
  return { jsonrpc: "2.0", id, result: value };
}

function rpcError(id: Id, code: number, message: string) {
  return { jsonrpc: "2.0", id, error: { code, message } };
}

function json(value: unknown): Response {
  return new Response(JSON.stringify(value), {
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });
}
