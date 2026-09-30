import path from 'node:path'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: {
    // The light-rays chunk (three.js) is lazy-loaded after first paint.
    chunkSizeWarningLimit: 600,
    // The site, and Mission Control (served by the worker, signed in only).
    rollupOptions: {
      input: { main: path.resolve(__dirname, 'index.html'), admin: path.resolve(__dirname, 'admin.html') },
    },
  },
  resolve: {
    alias: { '@': path.resolve(__dirname, './src') },
  },
})
