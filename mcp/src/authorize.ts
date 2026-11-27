// The consent page at /authorize. You approve each MCP client once, with
// the password you stored as MCP_ACCESS_PASSWORD. Nothing else signs in.
import { AuthorizationError, CimdFetchError, type ConsentDescription } from "@cloudflare/workers-oauth-provider";
import { type Env, type GrantProps, READ_SCOPE, WRITE_SCOPE, writesAllowed } from "./env";

const MIN_PASSWORD = 20;

const escape = (value: string) => value.replace(/[&<>"']/g, (char) => `&#${char.charCodeAt(0)};`);

const frameHeaders = {
  "content-type": "text/html; charset=utf-8",
  "x-frame-options": "DENY",
  "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
  "cache-control": "no-store",
};

export async function authorize(request: Request, env: Env): Promise<Response> {
  const oauth = env.OAUTH_PROVIDER;
  try {
    if ((env.MCP_ACCESS_PASSWORD ?? "").length < MIN_PASSWORD) {
      return text(`Set MCP_ACCESS_PASSWORD to a password of ${MIN_PASSWORD} characters or more first.`, 503);
    }
    if (request.method === "GET") {
      const authRequest = await oauth.parseAuthRequest(request);
      const details = await oauth.describeConsent(authRequest);
      const consent = await oauth.beginConsent(authRequest);
      for (const [key, value] of Object.entries(frameHeaders)) consent.headers.set(key, value);
      return new Response(page(details, consent.handle, env), { headers: consent.headers });
    }
    if (request.method !== "POST") return text("Use GET or POST.", 405);

    const form = await request.formData();
    const handle = String(form.get("handle") ?? "");
    if (form.get("decision") !== "approve") {
      const denied = await oauth.denyConsent(request, handle);
      return new Response(null, { status: 302, headers: denied.headers });
    }
    if (!(await samePassword(String(form.get("password") ?? ""), env.MCP_ACCESS_PASSWORD))) {
      // Slow down guessing; the page and its handle stay usable.
      await new Promise((resolve) => setTimeout(resolve, 1500));
      return text("Wrong password. Go back and try again.", 403);
    }
    const scope = [READ_SCOPE, ...(writesAllowed(env) && form.get("write") === "on" ? [WRITE_SCOPE] : [])];
    const approved = await oauth.approveConsent(request, handle, { scope });
    const client = await oauth.lookupClient(approved.request.clientId);
    const props: GrantProps = { clientName: client?.clientName ?? "unknown" };
    const { redirectTo } = await oauth.completeAuthorization({
      request: approved.request,
      userId: "owner",
      metadata: { clientName: props.clientName },
      scope: approved.request.scope,
      props,
    });
    approved.headers.set("Location", redirectTo);
    return new Response(null, { status: 302, headers: approved.headers });
  } catch (error) {
    if (error instanceof AuthorizationError && error.redirectTo) {
      return Response.redirect(error.redirectTo, 302);
    }
    if (error instanceof AuthorizationError) return text(error.description, 400);
    if (error instanceof CimdFetchError) return text("This app could not be verified.", 400);
    throw error;
  }
}

function page(details: ConsentDescription, handle: string, env: Env): string {
  const name = escape(details.clientName);
  const origin = details.clientDomain
    ? `Published by <strong>${escape(details.clientDomain)}</strong>.`
    : "This app registered itself; its name is not verified.";
  const write = writesAllowed(env)
    ? `<p><label><input type="checkbox" name="write"${details.scope.includes(WRITE_SCOPE) ? " checked" : ""}>
       Also let it make changes: fill a line's Category and Personal/Business, fix a payee, date or memo,
       and undo its own changes. Lines stay Unreviewed until you review them in the app.</label></p>`
    : "<p>It can read the budget. This server makes no changes.</p>";
  return `<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Allow ${name}?</title>
<style>body{font:16px system-ui,sans-serif;max-width:32rem;margin:2rem auto;padding:0 1rem;color:#17191b}
input[type=password]{width:100%;padding:.6rem;font-size:1rem;box-sizing:border-box}
button{padding:.6rem 1rem;font-size:1rem;margin-right:.5rem}.warn{color:#8f3f09}</style>
<h1>Allow ${name} to read your budget?</h1>
<p>${origin} Access goes to <strong>${escape(details.redirectHost)}</strong>.</p>
${details.redirectIsLoopback ? '<p class="warn"><strong>This sends access to an app on your computer.</strong> Continue only if you just started connecting from it.</p>' : ""}
<form method="post">
  <input type="hidden" name="handle" value="${escape(handle)}">
  ${write}
  <p><label>Password<br><input type="password" name="password" autocomplete="current-password" required></label></p>
  <p><button name="decision" value="approve">Allow</button><button name="decision" value="deny" formnovalidate>Deny</button></p>
</form>`;
}

async function samePassword(given: string, expected: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(given)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  return crypto.subtle.timingSafeEqual(a, b);
}

function text(message: string, status: number): Response {
  return new Response(escape(message), { status, headers: frameHeaders });
}
