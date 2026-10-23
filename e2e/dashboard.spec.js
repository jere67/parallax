// Each dashboard page in a real browser, on every device in the matrix (playwright.config.js):
// it renders its data, logs no errors, and fits the screen's width.
import { expect, test as base } from "@playwright/test";

// Every test fails on a console error or an uncaught exception, and attaches a full-page shot.
const test = base.extend({
  clean: [
    async ({ page }, use, info) => {
      const errors = [];
      page.on("pageerror", (err) => errors.push(err.message));
      page.on("console", (msg) => {
        if (msg.type() === "error") {
          errors.push(msg.text());
        }
      });
      await use();
      await info.attach("page", { body: await page.screenshot({ fullPage: true }), contentType: "image/png" });
      expect(errors, "console errors").toEqual([]);
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
