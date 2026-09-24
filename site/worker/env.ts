export interface Env {
  ASSETS: Fetcher
  DB: D1Database
  /** The dashboard's sign-in secret (wrangler secret put ADMIN_TOKEN). */
  ADMIN_TOKEN?: string
  /** Optional: a GitHub token for higher rate limits and Sponsors totals. */
  GITHUB_TOKEN?: string
  /** Ko-fi's webhook verification token. */
  KOFI_TOKEN?: string
  /** Rate limits by address (kept in memory for a minute, never stored). */
  CHECKS_LIMIT?: RateLimit
  SIGN_IN_LIMIT?: RateLimit
}
