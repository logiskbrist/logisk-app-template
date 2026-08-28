export const dynamic = 'force-dynamic'

export async function GET() {
  // `tag` is the image tag this container was built from (baked in by the
  // Dockerfile via the IMAGE_TAG build-arg). verify-preview and verify-prod
  // poll this to know whether the deploy they're waiting for is actually live.
  return Response.json({ status: 'ok', tag: process.env.IMAGE_TAG ?? null })
}
