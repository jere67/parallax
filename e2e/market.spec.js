// The screener and a stock's page in a real browser, on every device in the matrix, against the
// demo server's invented market. Each test fails on a console error or an uncaught exception.
import { expect, test as base } from "@playwright/test";
import { logIn } from "./accounts.js";

const test = base.extend({
  clean: [
    async ({ page }, use, info) => {
      // The market pages are for signed-in readers, like the rest of the app.
      await logIn(page, "market");
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
  await page.goto("/app/screener");
  await expect(page.getByRole("heading", { level: 1, name: "Screener" })).toBeVisible();
  await expect(firstSymbol(page)).toContainText("AAPL");
  await expect(table(page).getByRole("columnheader", { name: "Mkt cap" })).toHaveAttribute("aria-sort", "descending");
  await fitsWidth(page);
});

test("screener: a filter narrows the table, goes in the address, and undoes with back", async ({ page }) => {
  await page.goto("/app/screener");
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
  await expect(page).toHaveURL(/\/app\/screener$/);
  await expect(firstSymbol(page)).toContainText("AAPL");
});

test("screener: a typed bound and a search work together", async ({ page }) => {
  await page.goto("/app/screener");
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
  await page.goto("/app/screener");
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
  await page.goto("/app/screener");
  await page.getByRole("button", { name: "Add NVDA to the watchlist" }).click();
  await page.getByRole("button", { name: /^Watchlist/ }).click();
  await expect(table(page).locator("tbody tr")).toHaveCount(1);
  await page.reload();
  await expect(firstSymbol(page)).toContainText("NVDA");
});

test("screener: a stock the agent decided on links to that decision's trail", async ({ page }) => {
  await page.goto("/app/screener");
  const decision = table(page).getByTestId("screener-decision").first();
  await expect(decision).toBeVisible();
  const href = await decision.getAttribute("href");
  expect(href).toMatch(/^\/app\/runs\/\d{4}-\d{2}-\d{2}\/[A-Z.]+$/);
  await fitsWidth(page);
  await decision.click();
  await expect(page).toHaveURL(new RegExp(`${href}$`));
  await expect(page.getByRole("navigation", { name: "Decision trail" })).toBeVisible();
  await expect(page.getByRole("heading", { level: 1, name: href.split("/").pop() })).toBeVisible();
});

test("stock: the header, the chart, its ranges, and its key figures", async ({ page }) => {
  await page.goto("/app/screener");
  await firstSymbol(page).click();
  await expect(page).toHaveURL(/\/app\/stocks\/AAPL$/);
  await expect(page.getByRole("heading", { level: 1, name: "Apple Inc." })).toBeVisible();
  await expect(page.getByRole("navigation", { name: "Breadcrumb" })).toContainText("Information Technology");
  await expect(page.locator("canvas").first()).toBeVisible();
  const ranges = page.getByRole("group", { name: "Chart range" });
  for (const range of ["1D", "5D", "YTD", "Max"]) {
    await ranges.getByRole("button", { name: new RegExp(`^${range}`) }).click();
    await expect(page.locator("canvas").first()).toBeVisible();
  }
  await page.getByRole("button", { name: "Candles" }).click();
  await expect(page.locator("canvas").first()).toBeVisible();
  await expect(page.getByText("Market cap", { exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: "From revenue to profit" })).toBeVisible();
  await fitsWidth(page);
});

test("stock: peers join the chart, up to three, and leave it", async ({ page }) => {
  await page.goto("/app/stocks/AAPL");
  const peers = page.getByRole("region", { name: "Peers for comparison" });
  const add = peers.getByRole("button", { name: /^Compare / });
  await expect(add.first()).toBeVisible();
  for (let i = 0; i < 3; i += 1) {
    await add.first().click();
    await expect(peers.getByRole("button", { name: /^Remove / })).toHaveCount(i + 1);
  }
  await expect(add.first()).toBeDisabled();
  await expect(page.getByRole("button", { name: "Candles" })).toHaveCount(0);
  await peers.getByRole("button", { name: /^Remove / }).first().click();
  await expect(peers.getByRole("button", { name: /^Remove / })).toHaveCount(2);
  await fitsWidth(page);
});

test("stock: every tab opens at its own address", async ({ page }) => {
  await page.goto("/app/stocks/MSFT");
  await expect(page.getByRole("heading", { level: 1, name: "Microsoft" })).toBeVisible();
  const tabs = page.getByRole("tablist", { name: "Stock sections" });
  const sections = [
    ["Financials", "financials", "Debt and cash"],
    ["Technicals", "technicals", "Indicators"],
    ["Forecasts", "forecasts", "The consensus over time"],
    ["Seasonals", "seasonals", "Returns by month"],
    ["News", "news", "Headlines"],
    ["Filings", "filings", "SEC filings"],
  ];
  for (const [name, slug, heading] of sections) {
    await tabs.getByRole("tab", { name }).click();
    await expect(page).toHaveURL(new RegExp(`/app/stocks/MSFT/${slug}$`));
    await expect(page.getByRole("heading", { name: heading })).toBeVisible();
    await fitsWidth(page);
  }
});

test("stock: an unknown symbol says so and leads back", async ({ page }) => {
  await page.goto("/app/stocks/ZZZZ");
  await expect(page.getByText("ZZZZ is not on the screener")).toBeVisible();
  await page.getByRole("link", { name: "Back to the screener" }).click();
  await expect(page).toHaveURL(/\/app\/screener$/);
});
