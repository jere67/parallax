// Waits until the server answers with a started team portfolio. The demo history is written by
// a job that runs once a minute, so a fresh server needs up to two minutes.
const LIMIT_MS = 240_000;

async function portfolio(baseURL) {
  const resp = await fetch(`${baseURL}/function/get_portfolio`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{}",
  });
  if (!resp.ok) {
    return null;
  }
  return (await resp.json())?.data?.result ?? null;
}

export default async function seeded(config) {
  const baseURL = config.projects[0].use.baseURL;
  const deadline = Date.now() + LIMIT_MS;
  let last = "no answer";
  while (Date.now() < deadline) {
    try {
      const view = await portfolio(baseURL);
      if (view?.started && view.orders?.length) {
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
