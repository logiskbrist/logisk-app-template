import { describe, expect, it } from 'vitest'

// Runs in two modes:
//   - `BASE_URL` set   → hits a real deployment (verify-preview sets this to the
//                        preview URL, so `pnpm test` becomes a smoke test).
//   - `BASE_URL` unset → imports the route handler directly, so `pnpm test`
//                        works locally with nothing running.
//
// The absolute-URL check is required, not defensive: `BASE_URL` is a reserved
// Vite key and Vitest always injects it into process.env as '/'. Only an
// http(s) URL means "a real deployment to smoke-test".
const raw = process.env['BASE_URL']
const baseUrl = raw && /^https?:\/\//i.test(raw) ? raw.replace(/\/$/, '') : null

describe('/api/health', () => {
  it('reports ok', async () => {
    if (baseUrl) {
      const res = await fetch(`${baseUrl}/api/health`)
      expect(res.status).toBe(200)
      expect((await res.json()).status).toBe('ok')
      return
    }

    const { GET } = await import('../app/api/health/route')
    const res = await GET()
    expect(res.status).toBe(200)
    expect((await res.json()).status).toBe('ok')
  })
})
