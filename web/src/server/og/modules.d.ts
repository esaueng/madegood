// Additional module types the Workers bundler (wrangler and @cloudflare/vite-plugin) loads:
// `.wasm` as a compiled WebAssembly.Module, `.bin` as an ArrayBuffer.
declare module "*.wasm" {
  const module: WebAssembly.Module;
  export default module;
}

declare module "*.bin" {
  const data: ArrayBuffer;
  export default data;
}
