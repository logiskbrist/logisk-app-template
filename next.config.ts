import type { NextConfig } from 'next'

const nextConfig: NextConfig = {
  // No `output: 'standalone'` — standalone strips node_modules from the runtime
  // image, which breaks `prisma migrate deploy` (Prisma CLI is a devDependency
  // binary that Next.js's file tracer doesn't see because your app code
  // doesn't import it). The full node_modules is copied by the Dockerfile
  // instead. Image is ~150 MB bigger; migrations at container start just work.
}

export default nextConfig
