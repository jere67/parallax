// Each dashboard page in a real browser, on every device in the matrix (playwright.config.js):
// it renders its data, logs no errors, and fits the screen's width.
import { expect, test as base } from "@playwright/test";
import { PASSWORD, logIn, makeAccount } from "./accounts.js";

// Every test fails on a console error or an uncaught exception, and attaches a full-page shot.
const test = base.extend({
  clean: [
    async ({ page }, use, info) => {
      const errors = [];
      const failures = [];
      page.on("response", (res) => {
        if (res.status() === 500) {
          failures.push(res.text().then((body) => body.includes("40001")).catch(() => false));
        }
      });
      page.on("pageerror", (err) => errors.push(err.message));
      page.on("console", (msg) => {
        if (msg.type() === "error") {
          errors.push(msg.text());
        }
      });
      await use();
      await info.attach("page", { body: await page.screenshot({ fullPage: true }), contentType: "image/png" });
      // A database conflict the client retried is not an error, though the browser logs its 500.
      let retried = (await Promise.all(failures)).filter(Boolean).length;
      // WebKit words a fetch cut off by leaving the page as an access-control failure; Chromium
      // stays silent about those and would still report a real one.
      // A test that sends a wrong password says so, since the browser logs the refusal it expects.
      const refusals = info.annotations.some((note) => note.type === "wrong password") ? /status of 40[01]/ : /$^/;
      const real = errors
        .filter((text) => !refusals.test(text))
        .filter((text) => !text.includes("due to access control checks"))
        .filter((text) => !(text.includes("status of 500") && retried-- > 0));
      expect(real, "console errors").toEqual([]);
    },
    { auto: true },
  ],
});

// The More button in whichever navigation the screen shows: the top bar, or a phone's tab bar.
async function openMore(page) {
  const more = page.locator("button:visible", { hasText: /^More$/ });
  await more.click();
  await expect(more).toHaveAttribute("aria-expanded", "true");
  return more;
}

// Against the device's width, not window.innerWidth: a phone browser widens its layout viewport
// to fit content that overflows, so innerWidth grows with the overflow it should reveal.
async function fitsWidth(page) {
  const scroll = await page.evaluate(() => document.documentElement.scrollWidth);
  expect(scroll, "page scrolls sideways").toBeLessThanOrEqual(page.viewportSize().width);
}

test("portfolio: headline figures, equity curve, positions, and activity", async ({ page }) => {
  await logIn(page);
  await page.goto("/app");
  await expect(page.getByRole("heading", { level: 1, name: "Your portfolio" })).toBeVisible();
  await expect(page.getByText("Demo data.")).toBeVisible();
  await expect(page.getByText("Equity", { exact: true }).first()).toBeVisible();
  await expect(page.locator("canvas").first()).toBeVisible();
  await expect(page.getByRole("heading", { name: "Open positions" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Activity" })).toBeVisible();
  await expect(page.getByText(/educational student project/i)).toBeVisible();
  await fitsWidth(page);
});

test("moving to another page starts it at the top, not where the last page was scrolled", async ({ page }) => {
  await logIn(page);
  await page.goto("/app");
  await expect(page.getByRole("heading", { name: "Activity" })).toBeVisible();
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBeGreaterThan(200);
  await page.locator("a[href='/app/runs']:visible").first().click();
  await expect(page).toHaveURL(/\/app\/runs$/);
  await expect(page.getByRole("heading", { name: "Shortlist" })).toBeVisible();
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBe(0);
});

test("more: Reports and Specialists sit behind More, which closes on Escape or a click elsewhere", async ({ page }) => {
  await logIn(page);
  await page.goto("/app");
  await expect(page.getByRole("heading", { level: 1, name: "Your portfolio" })).toBeVisible();
  for (const name of ["Reports", "Specialists"]) {
    await expect(page.getByRole("link", { name, exact: true })).toHaveCount(0);
  }
  let more = await openMore(page);
  await page.keyboard.press("Escape");
  await expect(more).toHaveAttribute("aria-expanded", "false");
  await expect(page.getByRole("link", { name: "Reports", exact: true })).toHaveCount(0);
  more = await openMore(page);
  await page.getByRole("heading", { level: 1, name: "Your portfolio" }).click();
  await expect(more).toHaveAttribute("aria-expanded", "false");
  await openMore(page);
  await page.getByRole("link", { name: "Specialists", exact: true }).click();
  await expect(page.getByRole("heading", { level: 1, name: "Specialists" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Specialists", exact: true })).toHaveCount(0);
  await fitsWidth(page);
});

test("run: the latest run's shortlist leads to a decision's full trail", async ({ page }) => {
  await logIn(page);
  await page.goto("/app/runs");
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Shortlist" })).toBeVisible();
  await fitsWidth(page);

  // A phone shows the shortlist as cards, and a wider screen as a table.
  const ticker = page.viewportSize().width < 768
    ? page.getByTestId("shortlist-card").first().getByRole("link")
    : page.locator('a[href^="/app/runs/"][href*="/"]').filter({ hasText: /^[A-Z.]+$/ }).first();
  const name = (await ticker.getAttribute("href")).split("/").pop();
  await ticker.click();
  await expect(page).toHaveURL(new RegExp(`/app/runs/\\d{4}-\\d{2}-\\d{2}/${name}$`));
  await expect(page.getByRole("heading", { level: 1, name })).toBeVisible();
  await expect(page.getByRole("navigation", { name: "Decision trail" })).toBeVisible();
  for (const section of ["research", "panel", "consensus", "arbiter", "gate", "orders"]) {
    await expect(page.locator(`#${section}`)).toBeAttached();
  }

  const specialist = page.locator("#panel [aria-expanded]").first();
  await specialist.scrollIntoViewIfNeeded();
  await specialist.click();
  await expect(specialist).toHaveAttribute("aria-expanded", "true");
  await fitsWidth(page);
});

// A signed-in account's endpoint calls, for finding the demo decisions a test needs.
function api(request, account) {
  return async (name, data = {}) => {
    const resp = await request.post(`/function/${name}`, { data, headers: { Authorization: `Bearer ${account.token}` } });
    expect(resp.ok(), await resp.text()).toBeTruthy();
    return (await resp.json()).data.result;
  };
}

// The latest run's decision trails, each with its ticker.
async function latestTrails(call) {
  const run = await call("get_run", { run_date: "" });
  const trails = [];
  for (const row of run.rows) {
    trails.push(await call("get_decision_trail", { run_date: run.run_date, ticker: row.ticker }));
  }
  return trails;
}

test("decision: the trail names its run and decision, and each order its client order ID", async ({ page, request }) => {
  const account = await logIn(page, "trail");
  const trails = await latestTrails(api(request, account));
  const traded = trails.find((t) => t.orders.some((o) => o.purpose !== "stop")) ?? trails[0];
  await page.goto(`/app/runs/${traded.run_date}/${traded.ticker}`);
  const ids = page.getByTestId("trail-ids");
  await expect(ids).toHaveText(new RegExp(`^Run\\s*${traded.run_date}\\s*Decision\\s*${traded.run_date}/${traded.ticker}$`));

  // Each research report says when it was written, and each source when it was published.
  const research = page.locator("#research");
  await expect(research.getByTestId("research-time").first()).toHaveText(/^As of [A-Z][a-z]{2} \d{1,2}, \d{1,2}:\d{2} (AM|PM) ET$/);
  await research.getByRole("button", { name: /^Show \d+ sources?$/ }).first().click();
  await expect(research.getByTestId("source-time").first()).toHaveText(/^· Published [A-Z][a-z]{2} \d{1,2}, \d{4}/);

  // The gate says when it ruled and on which decision.
  const gate = page.locator("#gate");
  if (traded.gate) {
    await expect(gate.getByTestId("gate-checked")).toContainText(`for decision ${traded.decision_id}`);
    await expect(gate.getByTestId("gate-checked")).toContainText(/ET/);
  }
  // Every order shows the client order ID the broker knows it by, and leads to the portfolio.
  const orders = page.locator("#orders");
  for (const o of traded.orders) {
    await expect(orders.locator("[data-testid=client-order-id]:visible", { hasText: o.client_order_id })).toBeVisible();
    if (o.purpose !== "stop") {
      expect(o.client_order_id).toContain(`${traded.run_date}-${traded.ticker}-`);
      expect(o.decision_id).toBe(traded.decision_id);
    }
  }
  await orders.getByRole("link", { name: "Every order on the Portfolio page" }).click();
  await expect(page.getByRole("heading", { level: 1, name: "Your portfolio" })).toBeVisible();
});

test("decision: every specialist shows, and a failure or missing evidence is not a neutral vote", async ({ page, request }) => {
  const account = await logIn(page, "trail");
  const trails = await latestTrails(api(request, account));
  for (const t of trails) {
    expect(t.specialists.map((s) => s.specialist)).toEqual(["fundamentals", "technical", "news", "macro", "flow"]);
  }
  const failed = trails.find((t) => t.specialists.some((s) => s.status === "failed"));
  const abstained = trails.find((t) => t.specialists.some((s) => s.status === "abstained"));
  expect(failed, "the demo's latest run has a failed specialist").toBeTruthy();
  expect(abstained, "the demo's latest run has an abstention").toBeTruthy();

  await page.goto(`/app/runs/${failed.run_date}/${failed.ticker}`);
  const panel = page.locator("#panel");
  await expect(panel.getByTestId("specialist")).toHaveCount(5);
  const news = panel.locator("[data-specialist=news]");
  await expect(news).toHaveAttribute("data-status", "failed");
  await expect(news.getByText("Failed", { exact: true })).toBeVisible();
  await expect(news.getByText("3 samples failed, so it did not vote.")).toBeVisible();
  await news.getByRole("button").click();
  await expect(news.getByText(/^Sample 1: RateLimitError/)).toBeVisible();
  await fitsWidth(page);

  await page.goto(`/app/runs/${abstained.run_date}/${abstained.ticker}`);
  const role = abstained.specialists.find((s) => s.status === "abstained").specialist;
  const row = page.locator(`#panel [data-specialist=${role}]`);
  await expect(row.getByText("Abstained (no evidence)").first()).toBeVisible();
  // A neutral Hold reads as a stance, never as the abstention's dashed tag.
  const voted = page.locator("#panel [data-status=voted]").first();
  await expect(voted.getByText("Abstained (no evidence)")).toHaveCount(0);
  await fitsWidth(page);
});

test("decision: a decision the risk gate blocked says so, and has no order", async ({ page, request }) => {
  const account = await logIn(page, "trail");
  const call = api(request, account);
  let blocked = null;
  for (const summary of await call("list_runs")) {
    const run = await call("get_run", { run_date: summary.run_date });
    const row = run.rows.find((r) => r.gate_outcome === "rejected");
    if (row) {
      blocked = await call("get_decision_trail", { run_date: run.run_date, ticker: row.ticker });
      break;
    }
  }
  expect(blocked, "the demo history has a blocked order").toBeTruthy();
  expect(blocked.orders.filter((o) => o.purpose !== "stop")).toEqual([]);

  await page.goto(`/app/runs/${blocked.run_date}/${blocked.ticker}`);
  const strip = page.getByRole("navigation", { name: "Decision trail" });
  await expect(strip.getByText("Gate blocked", { exact: true })).toBeVisible();
  await expect(strip.getByText("no order sent")).toBeVisible();
  const gate = page.locator("#gate");
  await expect(gate.getByText("Gate blocked", { exact: true }).first()).toBeVisible();
  await expect(gate.getByTestId("gate-blocked")).toContainText("nothing went to the broker");
  if (blocked.orders.length === 0) {
    await expect(page.locator("#orders").getByTestId("no-orders")).toContainText("the risk gate blocked");
  }
  await expect(page.locator("#orders").getByText("Broker rejected")).toHaveCount(0);
  await fitsWidth(page);
});

test("run: the risk gate's card reads in plain words, not the executor's note", async ({ page }) => {
  await logIn(page);
  await page.goto("/app/runs");
  const card = page.getByRole("region", { name: "Run", exact: true });
  await expect(card.getByText(/^\d+ of \d+ approved$/)).toBeVisible();
  await expect(card).not.toContainText(/pending_new|; /);
});

test("specialists: five roles show recent votes and scoring context", async ({ page }) => {
  await logIn(page, "specialists");
  await page.goto("/app/specialists");
  await expect(page.getByRole("heading", { level: 1, name: "Specialists" })).toBeVisible();
  for (const role of ["Fundamentals", "Technical", "News", "Macro", "Flow"]) {
    await expect(page.getByRole("heading", { name: role, exact: true })).toBeVisible();
  }
  await expect(page.getByText(/hit rate|awaiting scored directional votes/i).first()).toBeVisible();
  await fitsWidth(page);
});

test("results: the forward test against both baselines, and where the result came from", async ({ page }) => {
  await logIn(page, "results");
  await page.goto("/app/results");
  await expect(page.getByRole("heading", { level: 1, name: "Results" })).toBeVisible();
  await expect(page.getByText("Against the equal-weight shortlist")).toBeVisible();
  await expect(page.getByText("Against SPY buy-and-hold")).toBeVisible();
  for (const name of ["Against the baselines", "Screen", "Arbiter", "Specialist calibration", "Reliability"]) {
    await expect(page.getByRole("heading", { name, exact: true })).toBeVisible();
  }
  await expect(page.getByText(/The shortlist beat the rest in \d+ of \d+ runs?\./)).toBeVisible();
  await fitsWidth(page);
  await page.getByRole("link", { name: "Recent votes" }).click();
  await expect(page.getByRole("heading", { level: 1, name: "Specialists" })).toBeVisible();
});

test("news: the feed filters by address, and a story opens beside it or over it", async ({ page }) => {
  await logIn(page, "news");
  await page.goto("/app/news");
  await expect(page.getByRole("heading", { level: 1, name: "News" })).toBeVisible();
  const rows = page.locator("a.news-row");
  await expect(rows.first()).toBeVisible();
  await fitsWidth(page);
  const wide = page.viewportSize().width >= 1024;

  // A wide screen opens the newest story by itself, and a narrower one waits to be asked.
  const story = page.getByRole("region", { name: "Story" });
  if (wide) {
    await expect(story.getByRole("heading", { level: 2 })).toHaveText((await rows.first().locator(".news-head").innerText()).split("\n")[0]);
  } else {
    await expect(story).toBeHidden();
  }

  // The instrument filter narrows the feed, shows in the address, and survives a reload.
  await page.getByLabel("Instrument").selectOption("NVDA");
  await expect(page).toHaveURL(/ticker=NVDA/);
  await expect(rows.first().locator(".news-ticker")).toHaveText("NVDA");
  await page.reload();
  await expect(page.getByLabel("Instrument")).toHaveValue("NVDA");
  await expect(rows.first().locator(".news-ticker")).toHaveText("NVDA");

  // Opening a line shows its note, its sources, and the way to the decision behind it.
  const headline = (await rows.nth(1).locator(".news-head").innerText()).split("\n")[0];
  await rows.nth(1).click();
  await expect(page).toHaveURL(/\/news\/\d{4}-\d{2}-\d{2}\/NVDA\/\w+\/\d+\?ticker=NVDA/);
  await expect(story.getByRole("heading", { level: 2 })).toHaveText(headline);
  await expect(story.getByText("Sources", { exact: true })).toBeVisible();
  await expect(story.getByRole("link", { name: "See the decision trail" })).toBeVisible();
  await fitsWidth(page);

  // Closing keeps the filter, and leaves a wide screen's feed at full width.
  await page.getByRole("button", { name: wide ? "Close the story" : "All research" }).click();
  await expect(page).toHaveURL(/\/news\?ticker=NVDA$/);
  await expect(story).toBeHidden();
  await expect(rows.first()).toBeVisible();
});

test("news: a shared link keeps its filter through logging in", async ({ page }) => {
  const account = await makeAccount(page, "news-link");
  await page.goto("/news?ticker=NVDA");
  await expect(page).toHaveURL(/\/login\?next=%2Fapp%2Fnews%3Fticker%3DNVDA$/);
  await page.getByLabel("Email", { exact: true }).fill(account.username);
  await page.getByLabel("Password", { exact: true }).fill(account.password);
  await page.getByRole("button", { name: "Log in", exact: true }).click();
  await expect(page).toHaveURL(/\/app\/news\?ticker=NVDA$/);
  await expect(page.getByRole("heading", { level: 1, name: "News" })).toBeVisible();
});

test("news: search narrows the feed and says when nothing matches", async ({ page }) => {
  await logIn(page, "news");
  await page.goto("/app/news");
  const rows = page.locator("a.news-row");
  await expect(rows.first()).toBeVisible();
  const box = page.getByRole("searchbox", { name: "Search the research" });
  await box.fill("10-Q revenue");
  await expect(page).toHaveURL(/q=10-Q/);
  await expect(rows.first().locator(".news-head")).toContainText("10-Q");
  await box.fill("no note says this");
  await expect(page.getByText("No research matches")).toBeVisible();
  await page.getByRole("button", { name: "Clear filters" }).click();
  await expect(page).toHaveURL(/\/news$/);
  await expect(box).toHaveValue("");
  await expect(rows.first()).toBeVisible();
});

test("news: a story's address opens it directly, and a gone note says so", async ({ page, request }) => {
  const account = await logIn(page, "news");
  const feed = await request.post("/function/get_news_feed", { data: { desk: "macro", limit: 1 }, headers: { Authorization: `Bearer ${account.token}` } });
  const macro = (await feed.json()).data.result.items[0];
  await page.goto(`/app/news/${macro.id}`);
  const story = page.getByRole("region", { name: "Story" });
  await expect(story.getByRole("heading", { level: 2 })).toHaveText(macro.headline);
  await expect(story.getByRole("link", { name: "See the morning's run" })).toBeVisible();
  await page.goto("/app/news/2001-01-02/AAPL/news/0");
  await expect(story.getByText("This note could not be found.")).toBeVisible();
  await page.goto("/app/news/not-an-address");
  await expect(story.getByText("This note could not be found.")).toBeVisible();
});

test("news: a note from the news desk opens, though its address says news twice", async ({ page, request }) => {
  const account = await logIn(page, "news");
  const feed = await request.post("/function/get_news_feed", { data: { desk: "news", limit: 1 }, headers: { Authorization: `Bearer ${account.token}` } });
  const note = (await feed.json()).data.result.items[0];
  await page.goto(`/app/news/${note.id}`);
  const story = page.getByRole("region", { name: "Story" });
  await expect(story.getByRole("heading", { level: 2 })).toHaveText(note.headline);
  await expect(story.getByText("Sources", { exact: true })).toBeVisible();
});

test("news: going back from a story returns to the same place in the feed", async ({ page }) => {
  test.skip(page.viewportSize().width >= 1024, "on a wide screen the feed never leaves");
  await logIn(page, "news");
  await page.goto("/app/news");
  const rows = page.locator("a.news-row");
  await expect(rows.nth(20)).toBeAttached();
  // The feed rises 12px into place as it loads, so scrolling before that ends lands 12px off.
  await page.waitForFunction(() => document.getAnimations().every((a) => a.playState === "finished"));
  await rows.nth(20).scrollIntoViewIfNeeded();
  const scrolled = await page.evaluate(() => window.scrollY);
  expect(scrolled).toBeGreaterThan(0);
  await rows.nth(20).click();
  const story = page.getByRole("region", { name: "Story" });
  await expect(story.getByRole("heading", { level: 2 })).toBeVisible();
  await page.getByRole("button", { name: "All research" }).click();
  await expect(story).toBeHidden();
  expect(await page.evaluate(() => window.scrollY)).toBe(scrolled);
});

test("an unknown address says the page was not found", async ({ page }) => {
  await page.goto("/no-such-page");
  await expect(page.getByText("Page not found")).toBeVisible();
  await page.getByRole("link", { name: "Go to the front page" }).click();
  await expect(page).toHaveURL(/\/$/);

  await logIn(page);
  await page.goto("/app/no-such-page");
  await expect(page.getByText("Page not found")).toBeVisible();
  await page.getByRole("link", { name: "Go to your portfolio" }).click();
  await expect(page).toHaveURL(/\/app$/);
});

test("the theme starts dark, and a switch to light stays on reload", async ({ page }) => {
  await page.goto("/login");
  const html = page.locator("html");
  await page.getByRole("button", { name: "Switch to light theme" }).click();
  await expect(html).toHaveAttribute("data-theme", "light");
  await page.reload();
  await expect(html).toHaveAttribute("data-theme", "light");
  await page.getByRole("button", { name: "Switch to dark theme" }).click();
  await expect(html).toHaveAttribute("data-theme", "dark");
});

// --- The way in -------------------------------------------------------------------------------

test("landing: says what this is, and shows no one's data", async ({ page }) => {
  let private_calls = 0;
  page.on("request", (req) => {
    if (req.url().includes("/function/")) {
      private_calls += 1;
    }
  });
  await page.goto("/");
  await expect(page.getByRole("heading", { level: 1 })).toContainText("investment committee");
  await expect(page.getByRole("link", { name: "Log in" })).toBeVisible();
  await expect(page.getByRole("link", { name: "Create account" })).toBeVisible();
  await expect(page.getByText("An example with made-up votes, not a live result")).toBeVisible();
  await expect(page.getByText(/educational student project/i)).toBeVisible();
  await fitsWidth(page);
  expect(private_calls, "calls to the server").toBe(0);

  // The example's decision follows the bar.
  const decision = page.locator("[aria-live]");
  await expect(decision).toHaveText("Buy");
  await setSlider(page, "Your buy bar", 0.5);
  await expect(decision).toHaveText("No action");

  await page.getByRole("link", { name: "Create your agent" }).first().click();
  await expect(page).toHaveURL(/\/signup$/);
  await expect(page.getByRole("heading", { name: "Create your account" })).toBeVisible();
});

test("account: sign up, connect keys, log out, and log back in to where you were going", async ({ page }, info) => {
  info.annotations.push({ type: "wrong password" });
  const email = `new-${process.pid}-${Date.now()}@example.test`;

  await page.goto("/app/policy");
  await expect(page).toHaveURL(/\/login\?next=%2Fapp%2Fpolicy$/);
  await page.getByRole("link", { name: "Create account" }).click();
  await expect(page).toHaveURL(/\/signup/);
  await page.getByLabel("Email", { exact: true }).fill(email);
  await page.getByLabel("Password", { exact: true }).fill("short");
  await expect(page.getByRole("button", { name: "Create account", exact: true })).toBeDisabled();
  await page.getByLabel("Password", { exact: true }).fill(PASSWORD);
  await page.getByRole("button", { name: "Create account", exact: true }).click();
  // Signing up from a link still ends where the link was going.
  await expect(page).toHaveURL(/\/app\/policy$/);
  await expect(page.getByRole("heading", { level: 1, name: "Your policy" })).toBeVisible();

  await page.goto("/app/settings");
  await expect(page.getByRole("heading", { level: 1, name: "Settings" })).toBeVisible();
  await fitsWidth(page);
  const connect = page.getByRole("button", { name: "Check and connect" });
  const alpaca = page.getByRole("group", { name: "Alpaca paper account" });
  const openrouter = page.getByRole("group", { name: "OpenRouter" });

  // A wrong key says so, and nothing is stored.
  await alpaca.getByLabel("API key ID").fill("PKNOTAREALKEY0001");
  await alpaca.getByLabel("Secret key").fill("e2e-good-secret-value");
  await connect.click();
  await expect(page.getByRole("alert")).toContainText(/Alpaca/);
  await expect(page.getByText("Connected")).toHaveCount(0);

  // A live account is refused, whatever the key looks like.
  await alpaca.getByLabel("API key ID").fill("AKE2ELIVEKEY0001");
  await connect.click();
  await expect(page.getByRole("alert")).toContainText(/paper/i);

  // A paper key of this run's own, since no two agents may trade one account.
  const paperKey = `PKE2EGOOD${Date.now()}`;
  await alpaca.getByLabel("API key ID").fill(paperKey);
  await openrouter.getByLabel("API key").fill("sk-or-e2e-good-key-1");
  await connect.click();
  await expect(alpaca.getByText(/Connected/)).toBeVisible();
  await expect(openrouter.getByText(/Connected/)).toBeVisible();
  // Never shown again, here or after a reload, beyond its last characters.
  await expect(alpaca.getByLabel("API key ID")).toHaveValue("");
  await page.reload();
  await expect(alpaca.getByText(/Connected/)).toBeVisible();
  await expect(page.locator("body")).not.toContainText(paperKey);
  await expect(page.locator("body")).not.toContainText("sk-or-e2e-good-key-1");
  await fitsWidth(page);

  await page.getByRole("button", { name: "Log out" }).last().click();
  await expect(page).toHaveURL(/\/$/);
  await page.goto("/app/runs");
  await expect(page).toHaveURL(/\/login\?next=%2Fapp%2Fruns$/);

  await page.getByLabel("Email", { exact: true }).fill(email);
  await page.getByLabel("Password", { exact: true }).fill("not-the-password-1");
  await page.getByRole("button", { name: "Log in", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText(/do not match an account/i);
  await page.getByLabel("Password", { exact: true }).fill(PASSWORD);
  await page.getByRole("button", { name: "Log in", exact: true }).click();
  await expect(page).toHaveURL(/\/app\/runs$/);
  await expect(page.getByRole("heading", { name: "Shortlist" })).toBeVisible();
});

test("account: a crafted link cannot send someone elsewhere after logging in", async ({ page }) => {
  const account = await makeAccount(page, "next");
  await page.goto("/login?next=https://example.test/");
  await page.getByLabel("Email", { exact: true }).fill(account.username);
  await page.getByLabel("Password", { exact: true }).fill(account.password);
  await page.getByRole("button", { name: "Log in", exact: true }).click();
  await expect(page).toHaveURL(/\/app$/);
});

test("account: signing up with no link in mind goes to connecting keys", async ({ page }) => {
  await page.goto("/signup");
  await page.getByLabel("Email", { exact: true }).fill(`direct-${process.pid}-${Date.now()}@example.test`);
  await page.getByLabel("Password", { exact: true }).fill(PASSWORD);
  await page.getByRole("button", { name: "Create account", exact: true }).click();
  await expect(page).toHaveURL(/\/app\/settings$/);
  await expect(page.getByRole("heading", { level: 1, name: "Settings" })).toBeVisible();
});

test("account: an address from before the app moved still arrives", async ({ page }) => {
  await logIn(page);
  await page.goto("/runs");
  await expect(page).toHaveURL(/\/app\/runs$/);
  await expect(page.getByRole("heading", { name: "Shortlist" })).toBeVisible();
});

test("account: changing a password takes the current one, and the new one logs in", async ({ page }, info) => {
  info.annotations.push({ type: "wrong password" });
  const account = await logIn(page, "password");
  await page.goto("/app/settings");
  const panel = page.getByRole("group", { name: "Account" });
  await panel.getByLabel("Current password").fill("not-the-password-1");
  await panel.getByLabel("New password").fill("a-brand-new-password-1");
  await panel.getByRole("button", { name: "Change password" }).click();
  await expect(panel.getByRole("alert")).toBeVisible();

  await panel.getByLabel("Current password").fill(account.password);
  await panel.getByRole("button", { name: "Change password" }).click();
  await expect(panel.getByRole("status")).toContainText("Password changed");

  await panel.getByRole("button", { name: "Log out" }).click();
  await page.goto("/login");
  await page.getByLabel("Email", { exact: true }).fill(account.username);
  await page.getByLabel("Password", { exact: true }).fill("a-brand-new-password-1");
  await page.getByRole("button", { name: "Log in", exact: true }).click();
  await expect(page).toHaveURL(/\/app$/);
});

// A demo server shows demo history to everyone, so a new agent's first screen is seen here with the
// server's answers standing in. A page's routes do not see what passes through its service worker.
test.describe(() => {
  test.use({ serviceWorkers: "block" });

  test("portfolio: a new agent shows its next step until it has a closing mark", async ({ page }) => {
    await logIn(page, "setup");
    // The server's real answers, as they read for an agent with no history.
    const adjusted = (change) => async (route) => {
      const response = await route.fetch();
      const body = await response.json();
      change(body.data.result);
      await route.fulfill({ response, json: body });
    };
    await page.route("**/function/get_portfolio", adjusted((view) => {
      view.started = false;
      view.demo = false;
    }));
    await page.route("**/function/get_agent_settings", adjusted((settings) => {
      settings.demo = false;
      settings.managed = false;
      settings.ready = false;
    }));
    await page.goto("/app");
    await expect(page.getByRole("heading", { level: 1, name: "Set up your agent" })).toBeVisible();
    await page.getByRole("link", { name: "Connect your keys" }).click();
    await expect(page).toHaveURL(/\/app\/settings$/);
    // A background refresh may still be inside `adjusted` as the test ends, and it must not fail the run.
    await page.unrouteAll({ behavior: "ignoreErrors" });
  });
});

// Uses the demo server's existing reports; no model or broker calls.
test("reports: request a cached insight, and keep a private history", async ({ page }) => {
  test.setTimeout(180_000);
  const account = await logIn(page, "reports");
  await page.goto("/app/runs");
  const latestTicker = page.locator('a[href^="/app/runs/"][href*="/"]').filter({ hasText: /^[A-Z.]+$/ }).first();
  const symbol = (await latestTicker.textContent()).trim();
  await openMore(page);
  await page.getByRole("link", { name: "Reports", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Stock reports", exact: true })).toBeVisible();
  const request = page.getByRole("button", { name: "Request report", exact: true });
  await expect(request).toBeEnabled({ timeout: 90_000 });
  await page.getByLabel("S&P 500 stock").fill(symbol);
  await request.click();
  await expect(page.getByRole("heading", { name: "Specialist votes", exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Sources", exact: true })).toBeVisible();
  await expect(page.getByText("Demo report — invented prices and research.")).toBeVisible();
  const votes = page.getByRole("button", { name: /Specialist votes/ });
  await expect(votes).toHaveAttribute("aria-expanded", "true");
  await votes.click();
  await expect(votes).toHaveAttribute("aria-expanded", "false");
  await votes.click();
  await expect(votes).toHaveAttribute("aria-expanded", "true");
  const sources = page.getByRole("button", { name: /Sources/ });
  await sources.click();
  await expect(sources).toHaveAttribute("aria-expanded", "false");
  await sources.click();
  await expect(sources).toHaveAttribute("aria-expanded", "true");
  await fitsWidth(page);
  await request.click();
  await expect(page.locator("article")).toHaveCount(1);
  await page.goto("/app/settings");
  await page.getByRole("button", { name: "Log out" }).last().click();
  await page.goto("/login?next=/app/reports");
  await page.getByLabel("Email", { exact: true }).fill(account.username);
  await page.getByLabel("Password", { exact: true }).fill(account.password);
  await page.getByRole("button", { name: "Log in", exact: true }).click();
  await expect(page.locator("article")).toHaveCount(1);
});

// --- Policies ---------------------------------------------------------------------------------

async function openPolicy(page, name) {
  await logIn(page, name);
  await page.goto("/app/policy");
  await expect(page.getByRole("heading", { level: 1, name: "Your policy" })).toBeVisible();
}

// Drag a slider to a value the way a keyboard or a thumb would end up there.
async function setSlider(page, name, value) {
  await page.getByRole("slider", { name }).evaluate((el, v) => {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;
    setter.call(el, v);
    el.dispatchEvent(new Event("input", { bubbles: true }));
  }, String(value));
}

// The assistant is a sidebar on a wide screen and a sheet behind a button on a phone.
async function openAssistant(page) {
  const ask = page.getByRole("button", { name: "Ask", exact: true });
  if (await ask.isVisible()) {
    await ask.click();
  }
  await expect(page.getByRole("region", { name: "Policy assistant" })).toBeVisible();
}

async function closeAssistant(page) {
  const close = page.getByRole("button", { name: "Close the assistant" });
  if (await close.isVisible()) {
    await close.click();
  }
}

test("policy: a draft replays as it changes, and a save is a new version", async ({ page }) => {
  await openPolicy(page, "form");
  await expect(page.getByRole("heading", { name: "What it would have done" })).toBeVisible();
  await expect(page.getByText(/Nothing differs from what the run decided/)).toBeVisible();
  await setSlider(page, "Minimum agreement to buy", 1);
  await expect(page.getByText(/decisions? differs? from what the run decided/)).toBeVisible();
  await expect(page.getByTestId("replay-row").first()).toBeVisible();
  await expect(page.getByTestId("save-bar")).toBeVisible();
  await fitsWidth(page);

  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByTestId("save-bar")).toHaveCount(0);
  await expect(page.getByText("Version 1", { exact: true }).first()).toBeVisible();
  await page.reload();
  await expect(page.getByRole("slider", { name: "Minimum agreement to buy" })).toHaveValue("1");
  await page.getByRole("button", { name: "Restore the defaults" }).click();
  await expect(page.getByRole("slider", { name: "Minimum agreement to buy" })).toHaveValue("0.5");
  await expect(page.getByText("Restored", { exact: false }).first()).toBeVisible();
});

test("policy: a rule built in the form says what it does and changes the replay", async ({ page }) => {
  await openPolicy(page, "rule");
  await page.getByRole("button", { name: "Add a rule" }).click();
  const builder = page.getByTestId("rule-builder");
  await builder.getByLabel("What should it do?").selectOption("sell");
  await builder.getByLabel("Metric").selectOption("score");
  await builder.getByLabel("Comparison").selectOption("lt");
  await builder.getByLabel("Value", { exact: true }).fill("0.99");
  await builder.getByLabel("Name (optional)").fill("Sell everything");
  await builder.getByRole("button", { name: "Add rule" }).click();
  const rule = page.getByTestId("rule");
  await expect(rule).toHaveCount(1);
  await expect(rule).toContainText("Sell a held stock when");
  await expect(rule).toContainText("Sell everything");
  await fitsWidth(page);
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByTestId("save-bar")).toHaveCount(0);
  await page.getByRole("button", { name: "Pause R1" }).click();
  await expect(rule).toContainText("Paused");
  await page.getByRole("button", { name: "Delete R1" }).click();
  await expect(rule).toHaveCount(0);
  await page.getByRole("button", { name: "Discard" }).click();
  await expect(rule).toHaveCount(1);
});

test("policy: the assistant proposes in plain English, and only applying saves", async ({ page }) => {
  await openPolicy(page, "chat");
  await openAssistant(page);
  const assistant = page.getByRole("region", { name: "Policy assistant" });
  const input = assistant.getByLabel("Message the policy assistant");
  await input.fill("Don't buy anything with RSI above 70");
  await assistant.getByRole("button", { name: "Send" }).click();
  const proposal = assistant.getByTestId("proposal");
  await expect(proposal).toBeVisible({ timeout: 30_000 });
  await expect(proposal).toContainText("Added rule R1");
  await fitsWidth(page);

  await proposal.getByRole("button", { name: "Discard" }).click();
  await expect(proposal).toContainText("Discarded");
  await expect(page.getByTestId("rule")).toHaveCount(0);

  await input.fill("Don't buy anything with RSI above 70 please");
  await assistant.getByRole("button", { name: "Send" }).click();
  const second = assistant.getByTestId("proposal").last();
  await expect(second.getByRole("button", { name: "Apply" })).toBeVisible({ timeout: 30_000 });
  await second.getByRole("button", { name: "Apply" }).click();
  await expect(second).toContainText("Applied as v1");
  await closeAssistant(page);
  await expect(page.getByTestId("rule")).toContainText("Too hot");

  await openAssistant(page);
  await input.fill("Put half my money in one stock");
  await assistant.getByRole("button", { name: "Send" }).click();
  const refused = assistant.getByTestId("proposal").last();
  await expect(refused).toContainText("Cannot apply", { timeout: 30_000 });
  await expect(refused.getByRole("button", { name: "Apply" })).toHaveCount(0);
});

// A page's routes do not see requests that pass through its service worker.
test.describe(() => {
  test.use({ serviceWorkers: "block" });

  test("policy: a message that loses a database conflict is sent again without fuss", async ({ page }) => {
    await openPolicy(page, "conflict");
    await openAssistant(page);
    const assistant = page.getByRole("region", { name: "Policy assistant" });
    let refused = 0;
    await page.route("**/function/send_policy_message", async (route) => {
      if (refused === 0) {
        refused += 1;
        await route.fulfill({
          status: 500,
          contentType: "application/json",
          body: JSON.stringify({ ok: false, error: { code: "EXECUTION_ERROR", message: "{'C': '40001', 'M': 'could not serialize access'}" } }),
        });
      } else {
        await route.continue();
      }
    });
    const input = assistant.getByLabel("Message the policy assistant");
    await input.fill("Don't buy anything with RSI above 70");
    await assistant.getByRole("button", { name: "Send" }).click();
    await expect(assistant.getByTestId("proposal")).toBeVisible({ timeout: 30_000 });
    expect(refused).toBe(1);
    await expect(assistant.getByText("Could not send that")).toHaveCount(0);
    await expect(input).toHaveValue("");
  });
});

test("policy: a member's save is theirs alone", async ({ page, browser, baseURL }) => {
  await openPolicy(page, "member");
  const slider = page.getByRole("slider", { name: "Largest position" });
  await expect(slider).toBeEnabled();
  const before = await slider.inputValue();
  await setSlider(page, "Largest position", before === "0.08" ? 0.09 : 0.08);
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByTestId("save-bar")).toHaveCount(0);

  const other = await (await browser.newContext({ baseURL, serviceWorkers: "block" })).newPage();
  await openPolicy(other, "other");
  await expect(other.getByRole("slider", { name: "Largest position" })).toHaveValue(before);
  await other.context().close();
});

// The admin's account is shared across devices, so only one project walks its one save.
test("policy: the admin's save is the team agent's next version", async ({ page }, info) => {
  test.skip(info.project.name !== "desktop" || !process.env.E2E_ADMIN_PASSWORD, "the admin account is shared");
  await page.goto("/login?next=/app/policy");
  await page.getByLabel("Email", { exact: true }).fill("admin");
  await page.getByLabel("Password", { exact: true }).fill(process.env.E2E_ADMIN_PASSWORD);
  await page.getByRole("button", { name: "Log in", exact: true }).click();
  const slider = page.getByRole("slider", { name: "Largest position" });
  await expect(slider).toBeEnabled();
  const before = await slider.inputValue();
  const next = before === "0.08" ? "0.09" : "0.08";
  await setSlider(page, "Largest position", Number(next));
  await page.getByRole("button", { name: "Save", exact: true }).click();
  await expect(page.getByTestId("save-bar")).toHaveCount(0);
  await page.reload();
  await expect(slider).toHaveValue(next);
});

// --- A phone ----------------------------------------------------------------------------------

test("mobile: the bottom tabs reach each page, and targets are a thumb's size", async ({ page }) => {
  await logIn(page);
  await page.goto("/app");
  const tabs = page.getByRole("navigation", { name: "Main" });
  if (page.viewportSize().width >= 1024) {
    await expect(tabs).toBeHidden();
    return;
  }
  await expect(tabs).toBeVisible();
  for (const [name, path, heading] of [
    ["News", "/app/news", "News"],
    ["Runs", "/app/runs", "Shortlist"],
    ["Policy", "/app/policy", "In plain English"],
    ["Portfolio", "/app", "Open positions"],
  ]) {
    const tab = tabs.getByRole("link", { name, exact: true });
    const box = await tab.boundingBox();
    expect(box.height, `${name} tab height`).toBeGreaterThanOrEqual(44);
    await tab.click();
    await expect(page).toHaveURL(new RegExp(`${path}$`));
    await expect(tab).toHaveAttribute("aria-current", "page");
    await expect(page.getByRole("heading", { name: heading })).toBeVisible();
    await fitsWidth(page);
  }
  // Reports and Specialists sit behind More, which opens upward and lights while one is open.
  const more = tabs.getByRole("button", { name: "More", exact: true });
  await more.click();
  await expect(more).toHaveAttribute("aria-expanded", "true");
  for (const name of ["Reports", "Specialists"]) {
    const box = await tabs.getByRole("link", { name, exact: true }).boundingBox();
    expect(box.height, `${name} item height`).toBeGreaterThanOrEqual(44);
  }
  await tabs.getByRole("link", { name: "Specialists", exact: true }).click();
  await expect(page).toHaveURL(/\/app\/specialists$/);
  await expect(page.getByRole("heading", { level: 1, name: "Specialists" })).toBeVisible();
  await expect(more).toHaveAttribute("aria-expanded", "false");
  await expect(more).toHaveClass(/text-accent/);
});

// Nothing inside the page scrolls sideways either, which would hide a column off the edge.
async function noSidewaysPanels(page) {
  const panels = await page.evaluate(() =>
    [...document.querySelectorAll(".scroll-x, .overflow-auto")]
      .filter((el) => el.offsetParent && el.scrollWidth > el.clientWidth + 1)
      .map((el) => el.closest("section")?.querySelector("h2")?.textContent ?? el.className),
  );
  expect(panels, "panels that scroll sideways").toEqual([]);
}

test("mobile: tables are cards on a phone, and each card opens what it should", async ({ page }) => {
  const phone = page.viewportSize().width < 768;
  await logIn(page);
  await page.goto("/app");
  const position = page.getByTestId("position-card").first();
  const positionsTable = page.getByRole("columnheader", { name: "Avg cost" }).first();
  if (!phone) {
    await expect(positionsTable).toBeVisible();
    await expect(position).toBeHidden();
    return;
  }
  await expect(position).toBeVisible();
  await expect(positionsTable).toBeHidden();
  await fitsWidth(page);
  const details = position.getByRole("button", { name: "Thesis and details" });
  // Rounded: a layout's subpixel positions can read a hair under its true height.
  expect(Math.round((await details.boundingBox()).height)).toBeGreaterThanOrEqual(44);
  await details.click();
  await expect(position.getByText("Thesis", { exact: true })).toBeVisible();
  await expect(position.getByText("Avg cost")).toBeVisible();
  await fitsWidth(page);
  await page.getByRole("button", { name: /^Closed trades/ }).click();
  await expect(page.getByTestId("closed-card").first()).toBeVisible();
  await page.getByRole("button", { name: /^Orders/ }).click();
  await expect(page.getByTestId("order-card").first()).toBeVisible();
  await noSidewaysPanels(page);

  await page.getByRole("navigation", { name: "Main" }).getByRole("link", { name: "Runs", exact: true }).click();
  const card = page.getByTestId("shortlist-card").first();
  await expect(card).toBeVisible();
  await expect(page.getByRole("columnheader", { name: "Conviction" })).toBeHidden();
  await fitsWidth(page);
  await noSidewaysPanels(page);
  const filter = page.getByRole("button", { name: /^Buys/ });
  expect((await filter.boundingBox()).height).toBeGreaterThanOrEqual(36);
  await card.getByRole("link").click();
  await expect(page).toHaveURL(/\/app\/runs\/\d{4}-\d{2}-\d{2}\/[A-Z.]+$/);
  await expect(page.getByRole("navigation", { name: "Decision trail" })).toBeVisible();
  await fitsWidth(page);
  await noSidewaysPanels(page);
});

// A phone stacks its cards, so a long list must not run the page on for screens. Past that length
// WebKit on Linux also cannot take the full-page shot every test attaches.
test("mobile: a long list shows its newest cards, and more on request", async ({ page }) => {
  await logIn(page);
  await page.goto("/app");
  if (page.viewportSize().width >= 768) {
    return;
  }
  const orders = page.getByTestId("order-card");
  await expect(orders.first()).toBeVisible();
  await expect(orders).toHaveCount(10);
  const height = await page.evaluate(() => document.documentElement.scrollHeight);
  expect(height / page.viewportSize().height, "screens of scrolling").toBeLessThan(10);

  await page.getByRole("button", { name: "Show 10 more orders" }).click();
  await expect(orders).toHaveCount(20);
  await fitsWidth(page);

  const closedTab = page.getByRole("button", { name: /^Closed trades/ });
  await closedTab.click();
  const total = Number((await closedTab.textContent()).match(/\d+/)[0]);
  const closed = page.getByTestId("closed-card");
  await expect(closed).toHaveCount(Math.min(total, 10));
  const more = page.getByRole("button", { name: /^Show \d+ more closed trades?$/ });
  while (await more.isVisible()) {
    await more.click();
  }
  await expect(closed).toHaveCount(total);
});

test("mobile: the app can be installed and opens offline", async ({ page, request, browserName }) => {
  const manifest = await (await request.get("/manifest.json")).json();
  expect(manifest.display).toBe("standalone");
  expect(manifest.icons.map((icon) => icon.purpose)).toContain("maskable");
  for (const icon of manifest.icons) {
    expect((await request.get(icon.src)).status(), icon.src).toBe(200);
  }
  expect(manifest.start_url).toBe("/app");
  const worker = await request.get("/sw.js");
  expect(worker.headers()["content-type"]).toContain("javascript");
  await logIn(page, "offline");
  await expect(page.goto("/app")).resolves.toBeTruthy();
  expect(await page.locator('link[rel="manifest"]').getAttribute("href")).toBe("/manifest.json");
  expect(await page.locator('meta[name="viewport"]').getAttribute("content")).toContain("viewport-fit=cover");
  // Playwright's WebKit does not run service workers.
  if (browserName === "webkit") {
    return;
  }
  await page.evaluate(() => navigator.serviceWorker.ready);
  await page.reload();
  await expect.poll(() => page.evaluate(() => !!navigator.serviceWorker.controller)).toBe(true);
  // A second tab, since this one's own failed requests would count as console errors.
  await page.goto("about:blank");
  await page.context().setOffline(true);
  const offline = await page.context().newPage();
  await offline.goto("/app");
  await expect(offline.getByText("You are offline.")).toBeVisible();
  await offline.close();
  await page.context().setOffline(false);
});
