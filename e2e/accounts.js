// Accounts for the browser tests: one made through the API, and a browser already logged in as it.
import { expect } from "@playwright/test";

export const PASSWORD = "local-e2e-test-password";

// An account made through the API, for tests about what comes after signing up. The sign-up form
// has its own tests in dashboard.spec.js.
const accounts = { n: 0 };
export async function makeAccount(page, name) {
  accounts.n += 1;
  const username = `${name}-${process.pid}-${accounts.n}-${Date.now()}@example.test`;
  const credential = { type: "password", password: PASSWORD };
  const made = await page.request.post("/user/register", {
    data: { identities: [{ type: "username", value: username }], credential },
  });
  expect(made.ok(), await made.text()).toBeTruthy();
  const reply = await page.request.post("/user/login", {
    data: { identity: { type: "username", value: username }, credential },
  });
  expect(reply.ok(), await reply.text()).toBeTruthy();
  return { username, password: PASSWORD, token: (await reply.json()).data.token };
}

// With the browser already logged in as a new account, once: logging out in the test sticks.
export async function logIn(page, name = "reader") {
  const account = await makeAccount(page, name);
  await page.addInitScript((token) => {
    try {
      if (!sessionStorage.getItem("logged-in")) {
        sessionStorage.setItem("logged-in", "1");
        localStorage.setItem("jac_token", token);
      }
    } catch {
      // about:blank has no storage.
    }
  }, account.token);
  return account;
}
