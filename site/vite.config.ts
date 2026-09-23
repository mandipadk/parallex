import path from 'node:path'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: {
    // The light-rays chunk (three.js) is lazy-loaded after first paint.
    chunkSizeWarningLimit: 600,
  },
  resolve: {
    alias: { '@': path.resolve(__dirname, './src') },
  },
})
