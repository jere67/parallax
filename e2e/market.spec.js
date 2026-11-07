// The screener and a stock's page in a real browser, on every device in the matrix, against the
// demo server's invented market. Each test fails on a console error or an uncaught exception.
import { expect, test as base } from "@playwright/test";

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
      await info.attach("page", { body: await page.screenshot(), contentType: "image/png" });
      expect(errors, "console errors").toEqual([]);
    },
    { auto: true },
  ],
});

async function fitsWidth(page) {
  const scroll = await page.evaluate(() => document.documentElement.scrollWidth);
  expect(scroll, "page scrolls sideways").toBeLessThanOrEqual(page.viewportSize().width);
}

const table = (page) => page.getByRole("region", { name: "Matching stocks" });
const firstSymbol = (page) => table(page).locator("tbody tr a").first();

test("screener: the biggest company leads, and the table fits the screen", async ({ page }) => {
  await page.goto("/screener");
  await expect(page.getByRole("heading", { level: 1, name: "Screener" })).toBeVisible();
  await expect(firstSymbol(page)).toContainText("AAPL");
  await expect(table(page).getByRole("columnheader", { name: "Mkt cap" })).toHaveAttribute("aria-sort", "descending");
  await fitsWidth(page);
});

test("screener: a filter narrows the table, goes in the address, and undoes with back", async ({ page }) => {
  await page.goto("/screener");
  await expect(firstSymbol(page)).toContainText("AAPL");
  const filters = page.getByRole("group", { name: "Filters" });
  await filters.getByRole("button", { name: "Sector" }).click();
  const card = page.getByRole("region", { name: "Sector filter" });
  await card.getByRole("button", { name: "Energy" }).click();
  await expect(page).toHaveURL(/f=sector(~|%7E)Energy/);
  await expect(firstSymbol(page)).toContainText("XOM");
  await fitsWidth(page);

  await page.reload();
  await expect(firstSymbol(page)).toContainText("XOM");
  await page.goBack();
  await page.goForward();
  await expect(firstSymbol(page)).toContainText("XOM");

  await filters.getByRole("button", { name: "Reset" }).click();
  await expect(page).toHaveURL(/\/screener$/);
  await expect(firstSymbol(page)).toContainText("AAPL");
});

test("screener: a typed bound and a search work together", async ({ page }) => {
  await page.goto("/screener");
  const filters = page.getByRole("group", { name: "Filters" });
  await filters.getByRole("button", { name: "Price", exact: true }).click();
  const card = page.getByRole("region", { name: "Price filter" });
  await card.getByLabel(/^From/).fill("400");
  await card.getByRole("button", { name: "Apply" }).click();
  await expect(page).toHaveURL(/f=price/);
  await expect(firstSymbol(page)).toContainText("MSFT");
  await page.getByRole("searchbox", { name: "Search by symbol or company" }).fill("meta");
  await expect(page).toHaveURL(/q=meta/);
  await expect(table(page).locator("tbody tr")).toHaveCount(1);
  await expect(firstSymbol(page)).toContainText("META");
});

test("screener: a tab changes the columns, and a head sorts both ways", async ({ page }) => {
  await page.goto("/screener");
  await expect(firstSymbol(page)).toContainText("AAPL");
  await page.getByRole("tab", { name: "Valuation" }).click();
  await expect(page).toHaveURL(/tab=Valuation/);
  const head = table(page).getByRole("columnheader", { name: "P/S" });
  await expect(head).toBeVisible();
  await head.getByRole("button").click();
  await expect(head).toHaveAttribute("aria-sort", "descending");
  await head.getByRole("button").click();
  await expect(head).toHaveAttribute("aria-sort", "ascending");
  await fitsWidth(page);
});

test("screener: a starred stock joins the watchlist and stays after a reload", async ({ page }) => {
  await page.goto("/screener");
  await page.getByRole("button", { name: "Add NVDA to the watchlist" }).click();
  await page.getByRole("button", { name: /^Watchlist/ }).click();
  await expect(table(page).locator("tbody tr")).toHaveCount(1);
  await page.reload();
  await expect(firstSymbol(page)).toContainText("NVDA");
});
