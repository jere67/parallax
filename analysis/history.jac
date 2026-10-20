"""Daily bars and trading sessions for after-the-close work: vote scoring and the simulated
baselines. Tests pass fakes; the defaults call Alpaca."""
import from research.alpaca { Bar, daily_bars, market_calendar }
import from research.collector { run_budget }

obj History {
    has bars: Callable[[list[str], str, str], dict[str, dict[str, Bar]]] | None = None,
        sessions: Callable[[str, str], list[str]] | None = None;

    """Each symbol's daily bars from `start` through `end` by session; a symbol with none is
    left out. `end` must be a session whose bar is final."""
    def read_bars(symbols: list[str], start: str, end: str) -> dict[str, dict[str, Bar]] {
        if self.bars is not None {
            return self.bars(symbols, start, end);
        }
        (series, _gaps) = daily_bars(symbols, start, end, run_budget());
        return {s.symbol: {b.day: b for b in s.bars} for s in series if s.bars};
    }

    """The trading sessions from `start` through `end`, in order."""
    def read_sessions(start: str, end: str) -> list[str] {
        if self.sessions is not None {
            return self.sessions(start, end);
        }
        return [d.day for d in market_calendar(start, end, run_budget())];
    }
}

def bar(day: str, close: float, open: float | None = None, low: float | None = None, high: float | None = None) -> Bar {
    o = open if open is not None else close;
    return Bar(day=day, open=o, high=high if high is not None else max(o, close), low=low if low is not None else min(o, close), close=close, volume=1000000.0, trades=1000, vwap=close);
}
