// Diagnostic — reveals which of a few known env vars are populated on the
// running pod, without leaking their values. Useful for confirming the
// ExternalSecret sync populated the container's environment as expected.

export const dynamic = 'force-dynamic'

export async function GET() {
  const keys = ['STRIPE_KEY', 'DATABASE_URL', 'API_KEY', 'PGHOST', 'PGDATABASE']
  const present = Object.fromEntries(keys.map((k) => [k, Boolean(process.env[k])]))
  return Response.json({ present })
}
