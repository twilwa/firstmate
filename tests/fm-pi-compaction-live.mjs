// Real CLI/RPC, agent loop, provider parser, compaction and generated extension.
// Only the localhost model transport is synthetic; no SDK installation needed.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { appendFileSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, readlinkSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { join } from "node:path";

const root = process.env.COMPACT_ROOT, state = process.env.COMPACT_STATE;
const busyPath = join(state, "compact.busy-state"), marker = join(state, "compact.model-stream");
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const busy = () => readFileSync(busyPath, "utf8");
// Protect actual configuration/authentication and installed extensions, including
// additions/deletions. Concurrent sessions are deliberately not part of config.
function realConfiguration() {
  const dir = process.env.REAL_PI_AGENT, files = {};
  function visit(path) {
    const stat = lstatSync(path);
    if (stat.isSymbolicLink()) files[path] = "link:" + readlinkSync(path);
    else if (stat.isDirectory()) for (const name of readdirSync(path).sort()) visit(join(path, name));
    else if (stat.isFile()) files[path] = createHash("sha256").update(readFileSync(path)).digest("hex");
  }
  if (existsSync(dir)) for (const name of readdirSync(dir).sort()) {
    const path = join(dir, name);
    if (!lstatSync(path).isDirectory() || name === "extensions") visit(path);
  }
  return files;
}
const original = realConfiguration();
const envFor = (dir) => {
  const env = { ...process.env, HOME: join(dir, "home"), PI_CODING_AGENT_DIR: join(dir, "agent"),
    XDG_CONFIG_HOME: join(dir, "config"), XDG_DATA_HOME: join(dir, "data"),
    XDG_CACHE_HOME: join(dir, "cache"), XDG_STATE_HOME: join(dir, "state"), TMPDIR: join(dir, "tmp") };
  for (const key of ["HOME", "PI_CODING_AGENT_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "TMPDIR"]) {
    assert.ok(env[key].startsWith(root + "/"), "Pi directory escaped temporary root");
    mkdirSync(env[key], { recursive: true });
  }
  return env;
};
const version = spawnSync(process.env.PI_EXECUTABLE, ["--version"], {
  env: envFor(join(root, "version")), cwd: root, encoding: "utf8", timeout: 15000,
});
assert.equal(version.status, 0, version.stderr);
assert.equal(version.stdout.trim(), "1.4.0", "this guard requires the verified Pi 1.4.0");

async function run(mode) {
  const dir = join(root, mode), env = envFor(dir), journal = join(dir, "events.jsonl");
  const events = () => existsSync(journal) ? readFileSync(journal, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : [];
  const seen = (name) => events().filter((e) => e.name === name);
  const until = async (predicate, description) => {
    const deadline = Date.now() + 20000;
    while (!predicate()) {
      if (child.exitCode !== null) throw new Error("Pi exited: " + stderr);
      if (Date.now() >= deadline) throw new Error(mode + ": timeout for " + description + "\n" + stderr + "\n" + JSON.stringify(events()));
      await delay(10);
    }
  };
  writeFileSync(join(env.PI_CODING_AGENT_DIR, "settings.json"), JSON.stringify({
    cacheWarming: "off", compaction: { enabled: false, keepRecentTokens: 1, reserveTokens: 512 },
    retry: { enabled: false },
  }));
  // Loaded AFTER the generated observer. Record real ctx.isIdle() and the busy
  // record at each public event; trigger the same post-settlement path as sol-pi.
  const probe = join(dir, "probe.ts");
  writeFileSync(probe, `
import { appendFileSync, existsSync, readFileSync } from "node:fs";
export default function (pi) {
  let compacted = false;
  const log = (name, ctx, extra = {}) => appendFileSync(${JSON.stringify(journal)}, JSON.stringify({
    name, at: Date.now(), idle: ctx.isIdle(), busy: readFileSync(${JSON.stringify(busyPath)}, "utf8"),
    stream: existsSync(${JSON.stringify(marker)}) ? readFileSync(${JSON.stringify(marker)}, "utf8") : "", ...extra
  }) + "\\n");
  pi.registerTool({name: "compact_probe", label: "probe", description: "Harmless local probe",
    parameters: {type: "object", properties: {}},
    execute: async () => ({content: [{type: "text", text: "probe complete"}]})});
  for (const name of ["agent_start", "context", "message_update", "message_end", "tool_execution_start", "session_before_compact", "session_compact", "session_compact_failed"]) {
    pi.on(name, (event, ctx) => { log(name, ctx, {
      role: event.message?.role,
      content: event.message?.role === "assistant" ? event.message.content : undefined,
      aborted: event.aborted, reason: event.reason
    }); });
  }
  pi.on("agent_settled", (_event, ctx) => {
    log("agent_settled", ctx);
    if (compacted || ${JSON.stringify(mode)} === "manual-idle") return;
    compacted = true;
    ctx.compact({
      onComplete: () => {
        log("compact_callback", ctx);
        if (${JSON.stringify(mode)} === "success") pi.sendUserMessage("Resume after compaction.");
      },
      onError: (error) => log("compact_error", ctx, {error: error.message}),
    });
  });
}
`);
  let calls = 0, held, settleDelay, stderr = "";
  const requests = [], errors = [];
  const chunk = (res, delta, finish = null) => res.write("data: " + JSON.stringify({
    id: "fixture", object: "chat.completion.chunk", created: 1, model: "probe",
    choices: [{ index: 0, delta, finish_reason: finish }],
  }) + "\n\n");
  const finish = (res, reason = "stop") => { chunk(res, {}, reason); res.end("data: [DONE]\n\n"); };
  const server = createServer(async (req, res) => {
    try {
      assert.equal(req.url, "/v1/chat/completions", "unexpected model endpoint");
      let body = "";
      for await (const part of req) body += part;
      requests.push(JSON.parse(body));
      calls += 1;
      // Two foreground requests (tool then completion); the third is the real
      // compaction summarizer. Hold its HTTP response until the parent checks.
      if (calls === 3) { held = res; return; }
      res.writeHead(200, { "content-type": "text/event-stream" });
      if (calls === 1) {
        chunk(res, { role: "assistant", reasoning_content: "checking" });
        chunk(res, { content: "preparing" });
        chunk(res, { tool_calls: [{ index: 0, id: "probe-call", type: "function", function: { name: "compact_probe", arguments: "{}" } }] });
        finish(res, "tool_calls");
      } else { chunk(res, { role: "assistant", content: "Completed. ".repeat(200) }); finish(res); }
    } catch (error) { errors.push(error); res.destroy(); }
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  writeFileSync(join(env.PI_CODING_AGENT_DIR, "models.json"), JSON.stringify({ providers: {
    "fm-compaction": { baseUrl: "http://127.0.0.1:" + server.address().port + "/v1", api: "openai-completions",
      apiKey: "synthetic-local-only", models: [{ id: "probe", name: "probe", contextWindow: 32768, maxTokens: 1024 }] },
  } }));
  const child = spawn(process.env.PI_EXECUTABLE, ["--mode", "rpc", "--no-session", "--no-extensions",
    "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files", "--no-tools",
    "-e", process.env.COMPACT_EXTENSION, "-e", probe, "--provider", "fm-compaction", "--model", "probe", "--thinking", "off"],
    { env, cwd: process.env.COMPACT_CWD, stdio: ["pipe", "pipe", "pipe"] });
  const exited = once(child, "exit");
  child.stderr.on("data", (data) => { stderr += data; });
  const rpc = [];
  let pending = "";
  child.stdout.setEncoding("utf8");
  // RPC uses LF framing; readline also splits valid Unicode separators inside JSON strings.
  child.stdout.on("data", (data) => {
    pending += data;
    let boundary;
    while ((boundary = pending.indexOf("\n")) !== -1) {
      const line = pending.slice(0, boundary);
      pending = pending.slice(boundary + 1);
      try { rpc.push(JSON.parse(line)); } catch { errors.push(new Error("invalid RPC: " + line)); }
    }
  });
  const send = (type, extra = {}) => child.stdin.write(JSON.stringify({ type, ...extra }) + "\n");
  try {
    send("prompt", { message: "Exercise a harmless tool, then summarize. ".repeat(200) });
    if (mode === "manual-idle") {
      // Operator /compact on a settled worker, with nothing resuming afterwards.
      await until(() => seen("agent_settled").length, "worker settlement");
      send("compact");
    }
    await until(() => held, "real compaction provider request");
    assert.equal(errors.length, 0, String(errors));
    assert.ok(seen("session_before_compact").length, "real compaction before event absent");
    assert.match(busy(), /state=busy source=pi-ext/, "compaction inherited settled idle");
    await delay(400);
    assert.match(busy(), /state=busy source=pi-ext/, "held compaction lost busy");
    const settled = seen("agent_settled")[0], before = seen("session_before_compact")[0];
    assert.match(settled.busy, /state=idle source=pi-ext/);
    assert.match(before.busy, /state=busy source=pi-ext/);
    assert.ok(before.at >= settled.at, "compaction did not follow settlement");
    const updates = seen("message_update").flatMap((e) => e.content ?? []);
    for (const [type, field] of [["text", "text"], ["thinking", "thinking"], ["toolCall", "arguments"]]) {
      assert.ok(updates.some((block) => block.type === type && block[field]), "Pi 1.4.0 guarded snapshot missing " + type);
    }
    const contexts = seen("context");
    assert.equal(contexts.length, 2, "foreground context boundaries changed");
    for (const context of contexts) assert.match(context.stream, /request=\d+ rev=1 ts=\d+/, "real context did not open stream evidence");
    const request = (record) => Number(record.match(/request=(\d+)/)[1]);
    assert.ok(request(contexts[1].stream) > request(contexts[0].stream), "next model request reused its predecessor identity");
    assert.ok(seen("message_update").some((e) => /rev=[2-9]\d* /.test(e.stream)), "real substantive snapshot did not advance stream progress");
    for (const event of seen("message_end").filter((e) => e.role === "assistant")) assert.equal(event.stream, "", "assistant end retained stream marker");
    assert.equal(seen("tool_execution_start").length, 1, "real tool execution missing");
    assert.equal(seen("tool_execution_start")[0].stream, "", "tool phase retained stream marker");
    assert.equal(existsSync(marker), false, "background compaction opened foreground stream evidence");
    if (mode === "abort") send("abort");
    else if (mode === "error") { held.writeHead(400, { "content-type": "application/json" }); held.end('{"error":{"message":"fixture compaction failure"}}'); }
    else { held.writeHead(200, { "content-type": "text/event-stream" }); chunk(held, { role: "assistant", content: "## Summary\nHarmless probe completed; resume the task." }); finish(held); }
    if (mode === "success") {
      await until(() => seen("agent_settled").length === 2, "resumed agent settlement");
      assert.match(seen("session_compact")[0].busy, /state=busy source=pi-ext/, "success prematurely published idle");
      assert.match(seen("compact_callback")[0].busy, /state=busy source=pi-ext/, "caller resumed from idle");
      assert.equal(seen("agent_start").length, 2, "successful compaction did not resume real agent work");
      await delay(2500);
      assert.match(busy(), /state=idle source=pi-ext event=agent-settled /, "compaction recheck overrode resumed work");
    } else if (mode === "manual-idle") {
      await until(() => seen("session_compact").length, "successful compaction");
      const done = seen("session_compact")[0];
      assert.match(done.busy, /state=busy source=pi-ext/, "success published idle before a caller could resume");
      await until(() => /state=idle/.test(busy()), "idle after successful compaction with no resumption");
      settleDelay = Date.now() - done.at;
      assert.ok(settleDelay >= 1500, "successful compaction settled without waiting for a resumption: " + settleDelay + "ms");
      assert.match(busy(), /state=idle source=pi-ext event=compaction-done-idle /);
      assert.equal(seen("agent_start").length, 1, "fixture unexpectedly resumed agent work");
    } else {
      await until(() => seen("session_compact_failed").length, "terminal compaction failure");
      const failed = seen("session_compact_failed")[0];
      assert.equal(failed.idle, true, "fixture did not exercise idle failure");
      assert.equal(failed.aborted, mode === "abort");
      assert.match(failed.busy, /state=idle source=pi-ext/, "failed idle compaction left busy stuck");
    }
    assert.match(busy(), /state=idle source=pi-ext/);
    assert.equal(errors.length, 0, String(errors));
    console.log("ok - real Pi 1.4.0 " + mode + ": stream snapshots, post-settlement busy and terminal outcome; idle-to-busy " + (before.at - settled.at) + "ms"
      + (settleDelay === undefined ? "" : "; compaction-to-idle " + settleDelay + "ms"));
  } finally {
    // Only this child; never signal a shared tmux server or a sibling worker.
    if (child.exitCode === null) child.kill("SIGTERM");
    await Promise.race([exited, delay(2000)]);
    if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL");
    await exited;
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
    appendFileSync(join(dir, "rpc.jsonl"), rpc.map((e) => JSON.stringify(e)).join("\n") + "\n");
  }
}
try {
  for (const mode of ["success", "manual-idle", "error", "abort"]) await run(mode);
} finally {
  assert.deepEqual(realConfiguration(), original, "real ~/.pi/agent configuration/auth/extensions changed");
  console.log("ok - real ~/.pi/agent configuration/auth/extensions unchanged; all Pi processes used temporary HOME/agent/XDG directories");
}
