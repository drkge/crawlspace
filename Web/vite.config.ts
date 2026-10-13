import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// `npm run dev` serves the UI with hot reload and passes API calls to a Crawlspace started with
// `crawlspace serve --dev`. Open the link that command prints so this browser gets its token.
// CRAWLSPACE_DEV_SERVER points it at another port, for a development copy beside the real app.
declare const process: { env: Record<string, string | undefined> }
const server = process.env.CRAWLSPACE_DEV_SERVER ?? 'http://127.0.0.1:7777'

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      '/api': { target: server, changeOrigin: true },
      '/auth': { target: server, changeOrigin: true },
    },
  },
  build: {
    outDir: 'dist',
    assetsDir: 'assets',
    sourcemap: false,
  },
})
