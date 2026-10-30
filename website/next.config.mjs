/** @type {import('next').NextConfig} */

// BASE_PATH is set to `/<repo-name>` by the GitHub Pages workflow so the
// exported site works from a project page (https://<user>.github.io/<repo>/).
// Locally it stays empty, so `npm run dev` and `npm run build` serve from `/`.
const basePath = process.env.BASE_PATH ?? "";

const nextConfig = {
  output: "export",
  basePath,
  env: {
    NEXT_PUBLIC_BASE_PATH: basePath,
  },
  images: {
    // Static export has no image optimizer server.
    unoptimized: true,
  },
  // Trailing slashes keep every route a real directory with an index.html,
  // which is what GitHub Pages serves most reliably.
  trailingSlash: true,
  // Mermaid runs only at build time (lib/mermaid-ssr.ts); keep it and jsdom
  // out of the server bundle so nothing from them reaches the client.
  serverExternalPackages: ["mermaid", "jsdom"],
};

export default nextConfig;
