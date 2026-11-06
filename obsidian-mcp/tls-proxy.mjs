// =============================================================================
// Obsidian MCP Server – TLS terminator
//
// The bundled server speaks plain HTTP only, and the MCP bearer token travels
// in a request header. This proxy accepts HTTPS on TLS_PORT and forwards every
// request unchanged to the server on 127.0.0.1:TARGET_PORT. Responses are
// streamed through as they arrive, so server-sent events keep working.
//
// Only Node built-ins: the upstream image already ships Node, and nothing has
// to be installed. Started by run.sh as uid 1000 with:
//   TLS_CERT, TLS_KEY  paths of the PEM certificate and key
//   TLS_PORT           listen port (default 8443)
//   TARGET_PORT        port of the MCP server (default 8787)
// =============================================================================

import { readFileSync } from "node:fs";
import http from "node:http";
import https from "node:https";

const listenPort = Number(process.env.TLS_PORT ?? 8443);
const targetPort = Number(process.env.TARGET_PORT ?? 8787);

// Hop-by-hop headers describe one connection, not the message, and must not
// be forwarded (RFC 9110, section 7.6.1).
const HOP_BY_HOP = new Set([
  "connection",
  "keep-alive",
  "proxy-connection",
  "transfer-encoding",
  "te",
  "trailer",
  "upgrade",
]);

function forwardableHeaders(headers) {
  const listed = String(headers.connection ?? "")
    .split(",")
    .map((name) => name.trim().toLowerCase())
    .filter(Boolean);
  const result = {};
  for (const [name, value] of Object.entries(headers)) {
    if (!HOP_BY_HOP.has(name) && !listed.includes(name)) {
      result[name] = value;
    }
  }
  return result;
}

const server = https.createServer(
  {
    cert: readFileSync(process.env.TLS_CERT),
    key: readFileSync(process.env.TLS_KEY),
  },
  (req, res) => {
    const headers = forwardableHeaders(req.headers);
    // Overwritten, not appended: a client must not be able to claim an
    // address of its choosing.
    headers["x-forwarded-for"] = req.socket.remoteAddress ?? "";
    headers["x-forwarded-proto"] = "https";
    if (req.headers.host) {
      headers["x-forwarded-host"] = req.headers.host;
    }

    const upstream = http.request(
      {
        host: "127.0.0.1",
        port: targetPort,
        method: req.method,
        path: req.url,
        headers,
      },
      (upRes) => {
        res.writeHead(upRes.statusCode ?? 502, forwardableHeaders(upRes.headers));
        upRes.pipe(res);
      },
    );

    upstream.on("error", (err) => {
      console.error(`[tls-proxy] upstream error: ${err.message}`);
      if (!res.headersSent) {
        res.writeHead(502, { "content-type": "text/plain" });
      }
      res.end();
    });

    // A client that goes away must not leave a stream open on the server.
    res.on("close", () => upstream.destroy());

    req.pipe(upstream);
  },
);

// MCP streams over server-sent events stay open for a long time, so there is
// no overall request timeout. The headers still have to arrive within 60 s.
server.requestTimeout = 0;
server.headersTimeout = 60_000;

server.on("tlsClientError", (err) => {
  console.error(`[tls-proxy] TLS handshake failed: ${err.message}`);
});

server.listen(listenPort, "0.0.0.0", () => {
  console.log(`[tls-proxy] HTTPS on port ${listenPort} -> 127.0.0.1:${targetPort}`);
});

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => {
    // Open event streams would otherwise keep close() waiting.
    server.close(() => process.exit(0));
    server.closeAllConnections();
  });
}
