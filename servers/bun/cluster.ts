export {};

const entry = process.argv[2];
const workers = Number(process.env.WORKERS ?? 1);
if (!entry || !Number.isSafeInteger(workers) || workers < 1) {
  throw new Error("Usage: WORKERS=<positive integer> bun cluster.ts <entry.ts>");
}

const children: Bun.Subprocess[] = [];
let stopping = false;
let exitCode = 0;

function stop(code: number): void {
  if (stopping) return;
  stopping = true;
  exitCode = code;
  for (const child of children) child.kill("SIGTERM");
}

for (const signal of ["SIGTERM", "SIGINT"] as const) {
  process.on(signal, () => stop(0));
}

try {
  for (let i = 0; i < workers; i++) {
    const child = Bun.spawn([process.execPath, entry], { env: process.env, stdio: ["inherit", "inherit", "inherit"] });
    children.push(child);
    void child.exited.then(() => {
      if (!stopping) stop(1);
    });
  }
} catch (error) {
  stop(1);
  console.error(error);
}

await Promise.all(children.map((child) => child.exited));
process.exit(exitCode);
