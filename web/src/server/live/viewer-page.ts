import type { Context } from "hono";

// Static presentation. The URL credential stays in the location and same-origin socket URL.
const script = `
const status = document.querySelector("#status");
const track = document.querySelector("#track");
function clear() {
  status.textContent = "Position unavailable";
  track.replaceChildren();
}
function connect() {
  const url = new URL("/api/live/" + encodeURIComponent(location.pathname.split("/").at(-1)), location.href);
  url.protocol = location.protocol === "https:" ? "wss:" : "ws:";
  const socket = new WebSocket(url);
  let timeout = setTimeout(() => { clear(); socket.close(); }, 15000);
  socket.onmessage = ({ data }) => {
    clearTimeout(timeout);
    timeout = setTimeout(() => { clear(); socket.close(); }, 15000);
    const view = JSON.parse(data);
    if (view.status !== "available") { clear(); return; }
    status.textContent = "Last shared position: " + view.current.lat + ", " + view.current.lon;
    const parts = view.segments.map((points) => {
      const list = document.createElement("ol");
      for (const point of points) {
        const item = document.createElement("li");
        item.textContent = point.lat + ", " + point.lon + " · " + new Date(point.capturedAtMs).toISOString();
        list.append(item);
      }
      return list;
    });
    track.replaceChildren(...parts);
  };
  socket.onerror = () => { clear(); socket.close(); };
  socket.onclose = ({ code }) => {
    clearTimeout(timeout);
    clear();
    if (code !== 1008) setTimeout(connect, 3000);
  };
}
connect();
`;

export function viewerPage(c: Context) {
  const nonce = crypto.randomUUID();
  c.header(
    "Content-Security-Policy",
    `default-src 'none'; connect-src 'self'; script-src 'nonce-${nonce}'; frame-ancestors 'none'`,
  );
  c.header("X-Robots-Tag", "noindex, nofollow");
  return c.html(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta property="og:title" content="MadeGood voyage position">
  <meta property="og:description" content="View a shared position. Not for navigation.">
  <title>MadeGood voyage position</title>
</head>
<body>
  <main>
    <h1>Voyage position</h1>
    <p>Not for navigation.</p>
    <p id="status" role="status">Position unavailable</p>
    <section id="track" aria-label="Shared track segments"></section>
  </main>
  <script nonce="${nonce}">${script}</script>
</body>
</html>`);
}
