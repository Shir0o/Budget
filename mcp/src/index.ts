// The cloud MCP server (ADR 0004): OAuth in front, the budget tools behind.
import { OAuthProvider } from "@cloudflare/workers-oauth-provider";
import { authorize } from "./authorize";
import { type Env, READ_SCOPE, WRITE_SCOPE } from "./env";
import { handleMcp, type McpContext } from "./mcp";

let provider: OAuthProvider<Env> | undefined;
let providerFor: string | undefined;

function oauth(env: Env): OAuthProvider<Env> {
  const origin = new URL(env.PUBLIC_URL).origin;
  if (provider && providerFor === origin) return provider;
  provider = new OAuthProvider<Env>({
    apiRoute: "/mcp",
    apiHandler: {
      fetch: (request, env, ctx) => handleMcp(request, env as Env, ctx as McpContext),
    },
    defaultHandler: {
      async fetch(request, env) {
        const url = new URL(request.url);
        if (url.pathname === "/authorize") return authorize(request, env as Env);
        if (url.pathname === "/") return new Response("Budget MCP server. Connect an MCP client to /mcp.");
        return new Response("Not found", { status: 404 });
      },
    },
    authorizeEndpoint: "/authorize",
    tokenEndpoint: "/token",
    clientRegistrationEndpoint: "/register",
    scopesSupported: [READ_SCOPE, WRITE_SCOPE],
    requiredScopes: [READ_SCOPE],
    resourceMetadata: {
      resource: `${origin}/mcp`,
      authorization_servers: [origin],
      bearer_methods_supported: ["header"],
      resource_name: "Budget",
    },
  });
  providerFor = origin;
  return provider;
}

export default {
  fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    if (!env.PUBLIC_URL) {
      return Promise.resolve(new Response("Set PUBLIC_URL in wrangler.jsonc.", { status: 503 }));
    }
    return oauth(env).fetch(request, env, ctx);
  },
} satisfies ExportedHandler<Env>;
