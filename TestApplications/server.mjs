import http from "node:http";

export function runServer(arguments_) {
  const [applicationName, commandName, rawPort, rawMockPort] = arguments_;
  const port = Number(rawPort);
  const mockPort = rawMockPort === undefined ? undefined : Number(rawMockPort);
  const applicationNumber = /#(\d+)/.exec(applicationName ?? "")?.[1];
  const host = "127.0.0.1";
  const address = `http://${host}:${port}`;

  if (
    !applicationName ||
    !applicationNumber ||
    !["dev:lab", "dev:mock", "mock"].includes(commandName) ||
    !Number.isInteger(port) ||
    (commandName === "dev:mock" && !Number.isInteger(mockPort))
  ) {
    console.error("Usage: node server.mjs <Application #N> <dev:lab|dev:mock|mock> <port> [mock-port]");
    process.exit(64);
  }

  function information() {
    return {
      application: applicationName,
      command: `yarn ${commandName}`,
      address,
      utc: new Date().toISOString(),
    };
  }

  function mockData() {
    return {
      message: `Test data from Mock server #${applicationNumber}`,
      mockServer: `Mock server #${applicationNumber}`,
      port,
      address,
      utc: new Date().toISOString(),
      items: [
        { id: 1, value: `mock-${applicationNumber}-alpha` },
        { id: 2, value: `mock-${applicationNumber}-beta` },
      ],
    };
  }

  function asText(info) {
    return [
      info.application,
      `Command: ${info.command}`,
      `Address: ${info.address}`,
      `UTC: ${info.utc}`,
    ].join("\n");
  }

  async function fetchMockData() {
    const mockAddress = `http://${host}:${mockPort}/api/test-data`;
    console.log(`[frontend] requesting ${mockAddress}`);
    const response = await fetch(mockAddress);
    if (!response.ok) throw new Error(`Mock server returned HTTP ${response.status}`);
    const data = await response.json();
    console.log(`[frontend] received ${JSON.stringify(data)}`);
    return data;
  }

  async function handleRequest(request, response) {
    const info = information();
    if (commandName === "mock") {
      const data = mockData();
      console.log(`[mock] ${request.method} ${request.url} -> ${JSON.stringify(data)}`);
      if (request.url === "/api/test-data") {
        response.writeHead(200, { "content-type": "application/json; charset=utf-8" });
        response.end(JSON.stringify(data, null, 2));
        return;
      }
      response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      response.end(htmlPage(info, "Mock API data", JSON.stringify(data, null, 2)));
      return;
    }

    if (commandName === "dev:mock") {
      try {
        const data = await fetchMockData();
        response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
        response.end(htmlPage(info, `Response from ${data.mockServer} on port ${data.port}`, JSON.stringify(data, null, 2)));
      } catch (error) {
        console.error(`[frontend] mock request failed: ${error.message}`);
        response.writeHead(502, { "content-type": "text/html; charset=utf-8" });
        response.end(htmlPage(info, "Mock request failed", error.message));
      }
      return;
    }

    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(htmlPage(info, "Lab mode", "No mock backend is used in this mode."));
  }

  const server = http.createServer((request, response) => {
    handleRequest(request, response).catch((error) => {
      console.error(error);
      if (!response.headersSent) response.writeHead(500, { "content-type": "text/plain; charset=utf-8" });
      response.end(error.message);
    });
  });

  server.listen(port, host, () => {
    console.log(asText(information()));
    if (commandName === "mock") {
      console.log(`Mock server #${applicationNumber} is serving test data on port ${port}`);
    }
    if (commandName === "dev:mock") probeMockServer();
  });

  async function probeMockServer() {
    for (let attempt = 1; attempt <= 30; attempt += 1) {
      try {
        await fetchMockData();
        return;
      } catch (error) {
        if (attempt === 30) {
          console.error(`[frontend] mock startup probe failed: ${error.message}`);
          return;
        }
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
    }
  }

  let stopping = false;
  function shutdown(signal) {
    if (stopping) return;
    stopping = true;
    console.log(`Stopping after ${signal} · UTC: ${new Date().toISOString()}`);
    server.close(() => process.exit(0));
    server.closeAllConnections();
    setTimeout(() => process.exit(0), 500);
  }

  process.on("SIGINT", () => shutdown("SIGINT / Ctrl+C"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
}

function htmlPage(info, heading, details) {
  return `<!doctype html>
<html>
<head><meta charset="utf-8"><title>${escapeHTML(info.application)}</title></head>
<body>
  <h1>${escapeHTML(info.application)}</h1>
  <pre>${escapeHTML([
    `Command: ${info.command}`,
    `Address: ${info.address}`,
    `UTC: ${info.utc}`,
  ].join("\n"))}</pre>
  <h2>${escapeHTML(heading)}</h2>
  <pre>${escapeHTML(details)}</pre>
</body>
</html>`;
}

function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
