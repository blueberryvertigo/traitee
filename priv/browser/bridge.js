import { chromium } from "playwright";
import { createInterface } from "readline";

let browser = null;
const pages = new Map();
let pageIdCounter = 1;

async function ensureBrowser(headless = true) {
  if (!browser || !browser.isConnected()) {
    browser = await chromium.launch({ headless });
  }
  return browser;
}

async function getPage(pageId) {
  const page = pages.get(pageId);
  if (!page || page.isClosed()) {
    throw new Error(`Page ${pageId} not found or closed`);
  }
  return page;
}

async function getActivePageId() {
  for (const [id, page] of pages) {
    if (!page.isClosed()) return id;
  }
  return null;
}

function formatAccessibilityNode(node, indent = 0) {
  if (!node) return "";
  const lines = [];
  const pad = "  ".repeat(indent);
  const role = node.role || "none";
  const name = node.name ? ` "${node.name}"` : "";
  const value = node.value ? ` value="${node.value}"` : "";
  const checked = node.checked !== undefined ? ` checked=${node.checked}` : "";
  const selected = node.selected !== undefined ? ` selected=${node.selected}` : "";
  const disabled = node.disabled ? " disabled" : "";
  const expanded = node.expanded !== undefined ? ` expanded=${node.expanded}` : "";

  if (role !== "none" && role !== "generic") {
    lines.push(`${pad}[${role}]${name}${value}${checked}${selected}${disabled}${expanded}`);
  }

  if (node.children) {
    for (const child of node.children) {
      lines.push(formatAccessibilityNode(child, indent + (role !== "none" && role !== "generic" ? 1 : 0)));
    }
  }
  return lines.filter(Boolean).join("\n");
}

const actions = {
  async navigate({ url, pageId, timeout = 30000 }) {
    const b = await ensureBrowser();
    let page;
    if (pageId && pages.has(pageId)) {
      page = await getPage(pageId);
    } else {
      const activeId = await getActivePageId();
      if (activeId) {
        page = pages.get(activeId);
        pageId = activeId;
      } else {
        const ctx = await b.newContext({ viewport: { width: 1280, height: 720 } });
        page = await ctx.newPage();
        pageId = pageIdCounter++;
        pages.set(pageId, page);
      }
    }
    await page.goto(url, { timeout, waitUntil: "domcontentloaded" });
    const title = await page.title();
    return { pageId, url: page.url(), title };
  },

  async snapshot({ pageId }) {
    const id = pageId || (await getActivePageId());
    if (!id) throw new Error("No active page");
    const page = await getPage(id);
    const tree = await page.accessibility.snapshot();
    const formatted = tree ? formatAccessibilityNode(tree) : "(empty page)";
    const url = page.url();
    const title = await page.title();
    return { pageId: id, url, title, snapshot: formatted };
  },

  async click({ selector, text, pageId, timeout = 5000 }) {
    const id = pageId || (await getActivePageId());
    if (!id) throw new Error("No active page");
    const page = await getPage(id);
    if (selector) {
      await page.click(selector, { timeout });
    } else if (text) {
      await page.getByText(text, { exact: false }).first().click({ timeout });
    } else {
      throw new Error("Either 'selector' or 'text' is required");
    }
    return { pageId: id, status: "clicked" };
  },

  async type({ text, selector, pageId, timeout = 5000 }) {
    const id = pageId || (await getActivePageId());
    if (!id) throw new Error("No active page");
    const page = await getPage(id);
    if (selector) {
      await page.fill(selector, text, { timeout });
    } else {
      await page.keyboard.type(text);
    }
    return { pageId: id, status: "typed" };
  },

  async fill({ selector, value, pageId, timeout = 5000 }) {
    const id = pageId || (await getActivePageId());
    if (!id) throw new Error("No active page");
    const page = await getPage(id);
    await page.fill(selector, value, { timeout });
    return { pageId: id, status: "filled" };
  },

  async screenshot({ pageId, fullPage = false, path }) {
    const id = pageId || (await getActivePageId());
    if (!id) throw new Error("No active page");
    const page = await getPage(id);
    const opts = { fullPage, type: "png" };
    if (path) opts.path = path;
    const buffer = await page.screenshot(opts);
    const base64 = buffer.toString("base64");
    return { pageId: id, format: "png", size: buffer.length, base64: base64.slice(0, 200) + "...(truncated)", savedTo: path || null };
  },

  async evaluate({ expression, pageId }) {
    const id = pageId || (await getActivePageId());
    if (!id) throw new Error("No active page");
    const page = await getPage(id);
    const result = await page.evaluate(expression);
    return { pageId: id, result: JSON.stringify(result, null, 2) };
  },

  async get_text({ pageId, selector }) {
    const id = pageId || (await getActivePageId());
    if (!id) throw new Error("No active page");
    const page = await getPage(id);
    let text;
    if (selector) {
      text = await page.locator(selector).innerText({ timeout: 5000 });
    } else {
      text = await page.innerText("body");
    }
    if (text.length > 15000) {
      text = text.slice(0, 15000) + "\n...(truncated)";
    }
    return { pageId: id, text };
  },

  async press_key({ key, pageId }) {
    const id = pageId || (await getActivePageId());
    if (!id) throw new Error("No active page");
    const page = await getPage(id);
    await page.keyboard.press(key);
    return { pageId: id, status: `pressed ${key}` };
  },

  async list_tabs() {
    const tabs = [];
    for (const [id, page] of pages) {
      if (page.isClosed()) continue;
      tabs.push({ pageId: id, url: page.url(), title: await page.title() });
    }
    return { tabs };
  },

  async new_tab({ url }) {
    const b = await ensureBrowser();
    const ctx = browser.contexts()[0] || (await b.newContext({ viewport: { width: 1280, height: 720 } }));
    const page = await ctx.newPage();
    const id = pageIdCounter++;
    pages.set(id, page);
    if (url) {
      await page.goto(url, { timeout: 30000, waitUntil: "domcontentloaded" });
    }
    return { pageId: id, url: page.url(), title: await page.title() };
  },

  async close_tab({ pageId }) {
    const id = pageId || (await getActivePageId());
    if (!id) throw new Error("No active page");
    const page = await getPage(id);
    await page.close();
    pages.delete(id);
    return { status: "closed", pageId: id };
  },

  async close() {
    if (browser) {
      await browser.close().catch(() => {});
      browser = null;
    }
    pages.clear();
    return { status: "browser closed" };
  },
};

const rl = createInterface({ input: process.stdin, terminal: false });

rl.on("line", async (line) => {
  let cmd;
  try {
    cmd = JSON.parse(line);
  } catch {
    process.stdout.write(JSON.stringify({ id: null, error: "Invalid JSON" }) + "\n");
    return;
  }

  const { id, action, params = {} } = cmd;

  if (!actions[action]) {
    process.stdout.write(JSON.stringify({ id, error: `Unknown action: ${action}` }) + "\n");
    return;
  }

  try {
    const result = await actions[action](params);
    process.stdout.write(JSON.stringify({ id, ok: true, result }) + "\n");
  } catch (err) {
    process.stdout.write(JSON.stringify({ id, ok: false, error: err.message }) + "\n");
  }
});

rl.on("close", async () => {
  if (browser) await browser.close().catch(() => {});
  process.exit(0);
});

process.on("SIGTERM", async () => {
  if (browser) await browser.close().catch(() => {});
  process.exit(0);
});

process.stderr.write("browser-bridge ready\n");
