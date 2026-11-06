// A local stand-in for OpenRouter, so the policy chat runs its whole path in a browser test, down
// to byLLM's real parser and the code that checks a proposal, without a key or a network. Start
// the server under test with OPENROUTER_API_BASE pointing here and any OPENROUTER_API_KEY.
//
// It answers from what the last message says, as a person would see the real model answer: a
// request to avoid hot stocks becomes a rule, a request for too much risk stays within the code's
// limits by being refused there, and anything else gets a plain reply.
import { createServer } from "node:http";

const PORT = Number(process.env.FAKE_OPENROUTER_PORT || 8399);

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
      res.end(JSON.stringify({ data: { free_model_daily_requests: { remaining: 1000 } } }));
    } else if (req.url.endsWith("/models")) {
      res.end(JSON.stringify({ data: [] }));
    } else {
      res.statusCode = 404;
      res.end("{}");
    }
  });
}).listen(PORT, "127.0.0.1", () => {
  console.log(`fake OpenRouter on ${PORT}`);
});
