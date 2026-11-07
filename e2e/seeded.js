// Waits until the server answers with a started demo portfolio. The demo history is written by
// a job that runs once a minute, so a fresh server needs up to two minutes.
const LIMIT_MS = 240_000;

async function post(baseURL, path, body, token) {
  return fetch(`${baseURL}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
}

// Reading a portfolio takes an account, and a demo server shows its history to any account.
async function signedUp(baseURL) {
  const username = `seeded-${Date.now()}@example.test`;
  const credential = { type: "password", password: "local-seeded-password" };
  await post(baseURL, "/user/register", { identities: [{ type: "username", value: username }], credential });
  const resp = await post(baseURL, "/user/login", { identity: { type: "username", value: username }, credential });
  return resp.ok ? (await resp.json())?.data?.token : null;
}

async function portfolio(baseURL, token) {
  const resp = await post(baseURL, "/function/get_portfolio", {}, token);
  if (!resp.ok) {
    return null;
  }
  return (await resp.json())?.data?.result ?? null;
}

export default async function seeded(config) {
  const baseURL = config.projects[0].use.baseURL;
  const deadline = Date.now() + LIMIT_MS;
  let last = "no answer";
  let token = null;
  while (Date.now() < deadline) {
    try {
      token ??= await signedUp(baseURL);
      const view = await portfolio(baseURL, token);
      if (view?.started && view.orders?.length) {
        // The first read of the runs walks the graph and holds up every other request, so it goes
        // now rather than during a test on a busy machine.
        await post(baseURL, "/function/list_runs", {}, token);
        return;
      }
      last = view ? "portfolio not started" : "no portfolio";
    } catch (err) {
      last = String(err);
    }
    await new Promise((done) => setTimeout(done, 2_000));
  }
  throw new Error(`${baseURL} has no seeded portfolio after ${LIMIT_MS / 1000}s (${last}). Start it with TRADING_AGENT_DEMO=1.`);
}
