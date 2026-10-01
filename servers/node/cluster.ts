import cluster from "node:cluster";
import { fileURLToPath } from "node:url";

if (cluster.isPrimary) {
  const workers = Number(process.env.WORKERS ?? 1);
  if (!Number.isSafeInteger(workers) || workers < 1) throw new Error("WORKERS must be a positive integer");
  cluster.setupPrimary({ exec: fileURLToPath(new URL("./server.ts", import.meta.url)) });
  let stopping = false;
  function shutdown(code: number) {
    if (stopping) return;
    stopping = true;
    process.exitCode = code;
    for (const worker of Object.values(cluster.workers ?? {})) worker?.kill("SIGTERM");
  }
  process.on("SIGTERM", () => shutdown(0));
  process.on("SIGINT", () => shutdown(0));
  cluster.on("exit", () => {
    if (!stopping) shutdown(1);
  });
  for (let index = 0; index < workers; index++) cluster.fork();
}
