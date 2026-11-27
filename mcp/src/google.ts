import type { Env } from "./env";

// One access token for Drive's app data folder, refreshed from the refresh
// token a few minutes before it expires. Kept in memory only.
let cached: { token: string; expires: number } | undefined;

export async function driveAccessToken(env: Env): Promise<string> {
  if (cached && cached.expires > Date.now() + 120_000) return cached.token;
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      client_id: env.GOOGLE_CLIENT_ID,
      client_secret: env.GOOGLE_CLIENT_SECRET,
      refresh_token: env.GOOGLE_REFRESH_TOKEN,
    }),
  });
  if (!response.ok) {
    // Never log the body: it can echo the request.
    throw new Error(`Google sign-in failed (${response.status}). Check the Google secrets.`);
  }
  const body = (await response.json()) as { access_token: string; expires_in: number };
  cached = { token: body.access_token, expires: Date.now() + body.expires_in * 1000 };
  return cached.token;
}
