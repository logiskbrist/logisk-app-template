export default function Home() {
  const appName = process.env.APP_NAME ?? 'logisk-app-template'
  return (
    <main style={{ fontFamily: 'system-ui, sans-serif', padding: '2rem', maxWidth: '40rem', margin: '0 auto' }}>
      <h1>hello from {appName}</h1>
      <p>
        This is the placeholder page shipped by <code>logisk-app-template</code>. Edit <code>app/page.tsx</code> to
        replace it with your own UI. Add API routes under <code>app/api/</code>.
      </p>
      <ul>
        <li>
          <a href="/api/health">/api/health</a> — used by kubelet probes
        </li>
        <li>
          <a href="/api/env-demo">/api/env-demo</a> — shows which env vars from Key Vault are populated
        </li>
      </ul>
    </main>
  )
}
