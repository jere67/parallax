// Each dashboard page in a real browser, on every device in the matrix (playwright.config.js):
// it renders its data, logs no errors, and fits the screen's width.
import { expect, test as base } from "@playwright/test";

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
      const real = errors
        .filter((text) => !text.includes("due to access control checks"))
        .filter((text) => !(text.includes("status of 500") && retried-- > 0));
      expect(real, "console errors").toEqual([]);
    },
    { auto: true },
  ],
});

// Against the device's width, not window.innerWidth: a phone browser widens its layout viewport
// to fit content that overflows, so innerWidth grows with the overflow it should reveal.
async function fitsWidth(page) {
  const scroll = await page.evaluate(() => document.documentElement.scrollWidth);
  expect(scroll, "page scrolls sideways").toBeLessThanOrEqual(page.viewportSize().width);
}

test("portfolio: headline figures, equity curve, positions, and activity", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByRole("heading", { level: 1, name: "Team portfolio" })).toBeVisible();
  await expect(page.getByText("Demo data.")).toBeVisible();
  await expect(page.getByText("Equity", { exact: true }).first()).toBeVisible();
  await expect(page.locator("canvas").first()).toBeVisible();
  await expect(page.getByRole("heading", { name: "Open positions" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Activity" })).toBeVisible();
  await expect(page.getByText(/educational student project/i)).toBeVisible();
  await fitsWidth(page);
});

test("run: the latest run's shortlist leads to a decision's full trail", async ({ page }) => {
  await page.goto("/runs");
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Shortlist" })).toBeVisible();
  await fitsWidth(page);

  const ticker = page.locator('a[href^="/runs/"][href*="/"]').filter({ hasText: /^[A-Z.]+$/ }).first();
  const name = (await ticker.textContent()).trim();
  await ticker.click();
  await expect(page).toHaveURL(new RegExp(`/runs/\\d{4}-\\d{2}-\\d{2}/${name}$`));
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

test("an unknown address says the page was not found", async ({ page }) => {
  await page.goto("/no-such-page");
  await expect(page.getByText("Page not found")).toBeVisible();
});

test("the theme switch changes the theme and keeps it on reload", async ({ page }) => {
  await page.goto("/");
  const html = page.locator("html");
  const toDark = page.getByRole("button", { name: "Switch to dark theme" });
  const toLight = page.getByRole("button", { name: "Switch to light theme" });
  await expect(toDark.or(toLight)).toBeVisible();
  const next = (await toDark.isVisible()) ? "dark" : "light";
  await (next === "dark" ? toDark : toLight).click();
  await expect(html).toHaveAttribute("data-theme", next);
  await page.reload();
  await expect(html).toHaveAttribute("data-theme", next);
});

// Uses the demo server's existing reports; no model or broker calls.
test("reports: sign in, request a cached insight, and retain private history", async ({ page }, info) => {
  test.setTimeout(180_000);
  await page.goto("/runs");
  const latestTicker = page.locator('a[href^="/runs/"][href*="/"]').filter({ hasText: /^[A-Z.]+$/ }).first();
  const symbol = (await latestTicker.textContent()).trim();
  await page.getByRole("link", { name: "Reports", exact: true }).click();
  await page.getByRole("button", { name: "New here? Create an account" }).click();
  const email = `reports-${info.project.name}-${Date.now()}@example.test`;
  await page.getByLabel("Email", { exact: true }).fill(email);
  await page.getByLabel("Password", { exact: true }).fill("local-report-test-password");
  await page.getByRole("button", { name: "Create account", exact: true }).click();
  await expect(page.getByRole("heading", { name: "Stock reports", exact: true })).toBeVisible();
  const request = page.getByRole("button", { name: "Request report", exact: true });
  await expect(request).toBeEnabled({ timeout: 90_000 });
  await page.getByLabel("S&P 500 stock").fill(symbol);
  await request.click();
  await expect(page.getByRole("heading", { name: "Specialist votes", exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Sources", exact: true })).toBeVisible();
  await expect(page.getByText("Demo report — invented prices and research.")).toBeVisible();
  await fitsWidth(page);
  await request.click();
  await expect(page.locator("article")).toHaveCount(1);
  await page.getByRole("button", { name: "Sign out", exact: true }).click();
  await page.getByLabel("Email", { exact: true }).fill(email);
  await page.getByLabel("Password", { exact: true }).fill("local-report-test-password");
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await expect(page.locator("article")).toHaveCount(1);
});

// --- Policies ---------------------------------------------------------------------------------

// Sign up on the Policy page with an account of this test's own.
async function signUpOnPolicy(page, info, name) {
  await page.goto("/policy");
  await page.getByRole("button", { name: "Sign in to make your own" }).click();
  await page.getByRole("button", { name: "New here? Create an account" }).click();
  await page.getByLabel("Email or username").fill(`${name}-${info.project.name}-${Date.now()}@example.test`);
  await page.getByLabel("Password", { exact: true }).fill("local-policy-test-password");
  await page.getByRole("button", { name: "Create account", exact: true }).click();
  await expect(page.getByRole("button", { name: "My policy" })).toHaveAttribute("aria-pressed", "true");
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

test("policy: a reader sees the team's policy and its replay, read-only", async ({ page }) => {
  await page.goto("/policy");
  await expect(page.getByRole("heading", { level: 1, name: "Policy" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "In plain English" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "What it would have done" })).toBeVisible();
  await expect(page.getByText(/No decision differs from the team's/)).toBeVisible();
  await expect(page.getByRole("slider", { name: "Largest position" })).toBeDisabled();
  await expect(page.getByRole("button", { name: "Add a rule" })).toHaveCount(0);
  await expect(page.getByRole("region", { name: "Policy assistant" })).toHaveCount(0);
  await fitsWidth(page);
});

test("policy: a draft replays as it changes, and a save is a new version", async ({ page }, info) => {
  await signUpOnPolicy(page, info, "form");
  await expect(page.getByText(/No decision differs from the team's/)).toBeVisible();
  await setSlider(page, "Minimum agreement to buy", 1);
  await expect(page.getByText(/decisions? differs? from the team's/)).toBeVisible();
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

test("policy: a rule built in the form says what it does and changes the replay", async ({ page }, info) => {
  await signUpOnPolicy(page, info, "rule");
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

test("policy: the assistant proposes in plain English, and only applying saves", async ({ page }, info) => {
  await signUpOnPolicy(page, info, "chat");
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

  test("policy: a message that loses a database conflict is sent again without fuss", async ({ page }, info) => {
    await signUpOnPolicy(page, info, "conflict");
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

test("policy: only the admin can change the team's, and a member is told so", async ({ page }, info) => {
  await signUpOnPolicy(page, info, "member");
  await page.getByRole("button", { name: "Team policy" }).click();
  await expect(page.getByText("Only the team's admin can change this policy.")).toBeVisible();
  await expect(page.getByRole("slider", { name: "Largest position" })).toBeDisabled();
  await page.getByRole("button", { name: "Sign out" }).click();
  await expect(page.getByRole("button", { name: "Sign in to make your own" })).toBeVisible();
});

// The admin's account is shared across devices, so only one project walks its one save.
test("policy: the admin's save becomes the team's next version", async ({ page }, info) => {
  test.skip(info.project.name !== "desktop" || !process.env.E2E_ADMIN_PASSWORD, "the admin account is shared");
  await page.goto("/policy");
  await page.getByRole("button", { name: "Sign in to make your own" }).click();
  await page.getByLabel("Email or username").fill("admin");
  await page.getByLabel("Password", { exact: true }).fill(process.env.E2E_ADMIN_PASSWORD);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.getByRole("button", { name: "Team policy" }).click();
  const slider = page.getByRole("slider", { name: "Largest position" });
  await expect(slider).toBeEnabled();
  const before = await slider.inputValue();
  await setSlider(page, "Largest position", before === "0.08" ? 0.09 : 0.08);
  await page.getByRole("button", { name: "Save for the next run" }).click();
  await expect(page.getByTestId("save-bar")).toHaveCount(0);
  await page.getByRole("button", { name: "Sign out" }).click();
  await expect(page.getByRole("slider", { name: "Largest position" })).toHaveValue(before === "0.08" ? "0.09" : "0.08");
});
