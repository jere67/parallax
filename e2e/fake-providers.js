// A local stand-in for OpenRouter, Alpaca, and Finnhub, so a browser test can connect a user's keys
// and run the policy chat's whole path, down to byLLM's real parser and the code that checks a
// proposal, without a key or a network. Start the server under test with OPENROUTER_API_BASE,
// ALPACA_BASE_URL, and FINNHUB_BASE_URL pointing here. The keys below are the good ones; any
// other is refused, as the real services would. A live Alpaca key reports a live account.
//
// It answers from what the last message says, as a person would see the real model answer: a
// request to avoid hot stocks becomes a rule, a request for too much risk stays within the code's
// limits by being refused there, and anything else gets a plain reply.
import { createServer } from "node:http";

const PORT = Number(process.env.FAKE_PROVIDERS_PORT || 8399);
const GOOD_ALPACA = "PKE2EGOODKEY0001";
const LIVE_ALPACA = "AKE2ELIVEKEY0001";
const GOOD_SECRET = "e2e-good-secret-value";
const GOOD_OPENROUTER = "sk-or-e2e-good-key-1";
const GOOD_FINNHUB = "e2e-good-finnhub-key";

function answer(prompt) {
  if (/half my money/i.test(prompt)) {
    return {
      reply: "That would put half your money in one stock, which is past the limit.",
      edits: [{ kind: "set", setting: "max_position_weight", value: 0.5 }],
    };
  }
  if (/rsi above/i.test(prompt)) {
    return {
      reply: "This rule blocks a buy while the stock's RSI is above 70. You can apply or discard it.",
      edits: [
        {
          kind: "add_rule",
          effect: "avoid_buy",
          label: "Too hot",
          conditions: [{ metric: "rsi_14", op: "gt", number: 70 }],
        },
      ],
    };
  }
  if (/stricter/i.test(prompt)) {
    return {
      reply: "This raises the score a stock needs before a buy. You can apply or discard it.",
      edits: [{ kind: "set", setting: "buy_score", value: 0.45 }],
    };
  }
  return { reply: "That stock's panel score was under this policy's bar, so it was not bought.", edits: [] };
}

function completion(request) {
  const messages = request.messages || [];
  const last = messages[messages.length - 1] || {};
  const text = typeof last.content === "string" ? last.content : JSON.stringify(last.content);
  // The prompt holds the catalog's own words, so read only the person's message from it.
  const asked = /message[^\n]*\n?\s*([^\n]*)/i.exec(text)?.[1] || text;
  return {
    id: "fake",
    object: "chat.completion",
    created: Math.floor(Date.now() / 1000),
    model: request.model,
    choices: [
      { index: 0, finish_reason: "stop", message: { role: "assistant", content: JSON.stringify(answer(asked)) } },
    ],
    usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 },
  };
}

createServer((req, res) => {
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => {
    res.setHeader("Content-Type", "application/json");
    if (req.method === "POST" && req.url.endsWith("/chat/completions")) {
      res.end(JSON.stringify(completion(JSON.parse(Buffer.concat(chunks).toString()))));
    } else if (req.url.endsWith("/key")) {
      const known = req.headers.authorization === `Bearer ${GOOD_OPENROUTER}` || req.headers.authorization === "Bearer e2e-fake";
      res.statusCode = known ? 200 : 401;
      res.end(JSON.stringify(known ? { data: { free_model_daily_requests: { used: 0, limit: 1000, remaining: 1000 } } } : { error: { message: "No auth credentials found" } }));
    } else if (req.url.startsWith("/v2/account")) {
      const key = req.headers["apca-api-key-id"];
      const known = (key === GOOD_ALPACA || key === LIVE_ALPACA) && req.headers["apca-api-secret-key"] === GOOD_SECRET;
      res.statusCode = known ? 200 : 403;
      res.end(JSON.stringify(known ? { account_number: key === LIVE_ALPACA ? "LIVE7890" : "PA3E2E7890", status: "ACTIVE", equity: "100000", cash: "100000" } : { message: "forbidden." }));
    } else if (req.url.startsWith("/v2/positions") || req.url.startsWith("/v2/orders")) {
      res.end("[]");
    } else if (req.url.includes("/quote")) {
      const known = req.headers["x-finnhub-token"] === GOOD_FINNHUB;
      res.statusCode = known ? 200 : 401;
      res.end(JSON.stringify(known ? { c: 500 } : { error: "Invalid API key" }));
    } else if (req.url.endsWith("/models")) {
      res.end(JSON.stringify({ data: [] }));
    } else {
      res.statusCode = 404;
      res.end("{}");
    }
  });
}).listen(PORT, "127.0.0.1", () => {
  console.log(`fake providers on ${PORT}`);
});
