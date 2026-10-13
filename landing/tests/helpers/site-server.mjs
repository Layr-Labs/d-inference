import { spawn } from "node:child_process";
import { once } from "node:events";
import { fileURLToPath } from "node:url";

export async function startSiteServer({ env = {} } = {}) {
  let origin;
  // Use localhost consistently: Next normalizes loopback IPs in request URLs.
  const server = spawn(process.execPath, [
    "node_modules/next/dist/bin/next", "start", "--hostname", "localhost", "--port", "0",
  ], {
    cwd: fileURLToPath(new URL("../../", import.meta.url)),
    env: {
      ...process.env,
      NODE_ENV: "production",
      NEXT_TELEMETRY_DISABLED: "1",
      DARKBLOOM_API_BASE_URL: "http://127.0.0.1:9/v1",
      DARKBLOOM_CONSOLE_STATS_URL: "http://127.0.0.1:9/api/stats",
      DARKBLOOM_API_KEY: "",
      DARKBLOOM_STORY_WEBHOOK_URL: "",
      DARKBLOOM_STORY_WEBHOOK_TOKEN: "",
      ...env,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  const stopped = once(server, "exit");
  await new Promise((resolve, reject) => {
    let output = "";
    const timeout = setTimeout(() => reject(new Error(`Server did not start. Run npm run build first.\n${output}`)), 20_000);
    const fail = (error) => { clearTimeout(timeout); reject(error); };
    server.once("error", fail);
    server.once("exit", (code) => fail(new Error(`Server exited (${code})\n${output}`)));
    const read = (chunk) => {
      output += chunk;
      const url = output.match(/http:\/\/localhost:\d+/)?.[0];
      if (url && output.includes("Ready in")) {
        clearTimeout(timeout);
        origin = url;
        resolve();
      }
    };
    server.stdout.on("data", read);
    server.stderr.on("data", read);
  });
  return {
    origin,
    async close() {
      if (server.exitCode !== null) return;
      server.kill("SIGTERM");
      const timeout = setTimeout(() => server.kill("SIGKILL"), 5_000);
      await stopped;
      clearTimeout(timeout);
    },
  };
}
