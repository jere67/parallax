// The dashboard's device matrix (GAP-13, TDD §10). Every page must render, without errors and
// without scrolling sideways, on each of these. The server is started separately, with the demo
// history (see README), and E2E_BASE_URL points at it.
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  globalSetup: "./seeded.js",
  timeout: 60_000,
  expect: { timeout: 15_000 },
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: 0,
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : "list",
  use: {
    baseURL: process.env.E2E_BASE_URL || "http://localhost:8000",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  projects: [
    { name: "desktop", use: { ...devices["Desktop Chrome"], viewport: { width: 1440, height: 900 } } },
    { name: "minimum", use: { ...devices["Pixel 7"], viewport: { width: 360, height: 640 } } },
    { name: "android-chrome", use: { ...devices["Pixel 7"] } },
    { name: "ios-safari", use: { ...devices["iPhone 15"] } },
  ],
});
