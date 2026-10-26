// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [answers-json]
// answers-json is an array of {question, selection, note} submitted against the
// rendered Captain's Call forms, so the answer context the page hands to lavish
// is observed as the page emits it.
// Prints one JSON document:
//   { stats:[{n,label}], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable}], call:[{question,options}], empty,
//     more, error, queued:[{prompt,tag,text,data}] }
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.name = "";
    this.listeners = {};
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      remove: (c) => {
        this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" ");
      },
      contains: (c) => this.className.split(/\s+/).includes(c),
      toggle: (c, on) => {
        const has = this.className.split(/\s+/).includes(c);
        const want = on === undefined ? !has : !!on;
        if (want) this.classList.add(c); else this.classList.remove(c);
      },
    };
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(type, fn) {
    (this.listeners[type] = this.listeners[type] || []).push(fn);
  }
  dispatch(type) {
    let prevented = false;
    const ev = { type, preventDefault: () => { prevented = true; } };
    (this.listeners[type] || []).forEach((fn) => fn.call(this, ev));
    return prevented;
  }
  descendants() {
    const out = [];
    const walk = (n) => { for (const c of n.children) { out.push(c); walk(c); } };
    walk(this);
    return out;
  }
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
const queued = [];
globalThis.window = {
  lavish: {
    queuePrompt: (prompt, opts) => {
      queued.push({ prompt, tag: opts.tag, text: opts.text, data: opts.data });
    },
  },
};
globalThis.TextEncoder = TextEncoder;
globalThis.FormData = class {
  constructor(form) {
    this.values = new Map();
    for (const node of form.descendants()) {
      if (!node.name) continue;
      if (node.type === "radio" || node.type === "checkbox") {
        if (node.checked) this.values.set(node.name, node.value);
      } else if (!this.values.has(node.name)) {
        this.values.set(node.name, node.value);
      }
    }
  }
  get(key) { return this.values.has(key) ? this.values.get(key) : null; }
};

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
// The page deals the next card on a timer; the shim answers cards directly, so
// it runs the render without one rather than holding the process open.
new Function("setTimeout", script)(() => 0);

for (const answer of JSON.parse(process.argv[3] || "[]")) {
  const deck = byId.get("bb-call");
  const form = (deck ? deck.descendants() : [])
    .find((n) => n.attributes["data-lavish-question"] === answer.question);
  if (!form) throw new Error("no Captain's Call form for " + answer.question);
  for (const node of form.descendants()) {
    if (node.type === "radio") node.checked = node.value === answer.selection;
    if (node.name === "note") node.value = answer.note || "";
  }
  form.dispatch("submit");
}

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

const rowsOf = (container) =>
  container.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const main = row.children.find((c) => c.className.includes("bb-row__main"));
      return {
        title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
        sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
        badges: badgesOf(row),
        pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
      };
    });

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);

const hasClass = (n, cls) => n.className.split(/\s+/).includes(cls);
const textIn = (n, cls) => {
  const hit = n.descendants().find((c) => hasClass(c, cls));
  return hit ? hit.textContent : null;
};
const call = (byId.get("bb-call") || new Node("div")).children
  .filter((c) => hasClass(c, "bb-decision"))
  .map((card) => {
    const form = card.descendants().find((n) => n.attributes["data-lavish-question"]);
    return {
      question: form ? form.attributes["data-lavish-question"] : "",
      options: (form ? form.descendants() : [])
        .filter((n) => hasClass(n, "bb-opt"))
        .map((o) => ({
          value: (o.descendants().find((c) => c.type === "radio") || {}).value ?? "",
          label: textIn(o, "bb-opt__label"),
          hint: textIn(o, "bb-opt__hint"),
          until: textIn(o, "bb-opt__until"),
        })),
    };
  });
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

process.stdout.write(
  JSON.stringify({ stats, underway, charted, call, empty, more, error: errorText, queued }) + "\n");
