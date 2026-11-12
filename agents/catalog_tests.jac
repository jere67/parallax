"""Choosing the run's free models from OpenRouter's list, against a local fake. No network."""
import os;
import from agents.catalog { MAX_CHAIN, PREFERRED_MODELS, ListedModel, choose_models, listed_models, resolve_models, usable }
import from agents.models { CHAIN, OPENROUTER_API_BASE_ENV, ROUTER_MODEL }
import from tests.fakes.openrouter { FakeOpenRouter }

glob TODAY: str = "2026-11-02";
glob TYPED: list[str] = ["structured_outputs", "response_format", "tools", "reasoning"];
glob fake: FakeOpenRouter = FakeOpenRouter();
glob base: str = fake.start();

def free(id: str, parameters: list[str] = TYPED, expires: str = "") -> ListedModel {
    return ListedModel(id=id, parameters=parameters, expires=expires);
}

def bare(model: str) -> str {
    return model.removeprefix("openrouter/");
}

"""Point the API base at the fake listing `rows`; returns what `restore` puts back."""
def use_fake(rows: list[dict[str, any]] | None) -> tuple[dict[str, str | None], list[str]] {
    fake.models = rows;
    saved = ({name: os.environ.get(name) for name in ["OPENROUTER_API_KEY", OPENROUTER_API_BASE_ENV]}, list(CHAIN.models));
    os.environ["OPENROUTER_API_KEY"] = "test-key";
    os.environ[OPENROUTER_API_BASE_ENV] = base;
    return saved;
}

def restore(saved: tuple[dict[str, str | None], list[str]]) {
    (env, saved_chain) = saved;
    for (name, value) in env.items() {
        if value is None {
            os.environ.pop(name, None);
        } else {
            os.environ[name] = value;
        }
    }
    CHAIN.reset(saved_chain);
}

def listed_from_fake(rows: list[dict[str, any]] | None) -> list[ListedModel] | None {
    saved = use_fake(rows);
    try {
        return listed_models();
    } finally {
        restore(saved);
    }
}

"""Resolve against the fake; returns the chain, the note, and the shared chain it set."""
def resolve_from_fake(rows: list[dict[str, any]] | None) -> tuple[list[str], str, list[str]] {
    saved = use_fake(rows);
    try {
        (chain, note) = resolve_models(TODAY);
        return (chain, note, list(CHAIN.models));
    } finally {
        restore(saved);
    }
}

test "the vetted models come first, in their order, wherever OpenRouter lists them" {
    listed = [free("other/model:free")] + [free(bare(m)) for m in reversed(PREFERRED_MODELS)];
    chain = choose_models(listed, TODAY);
    assert chain[:len(PREFERRED_MODELS)] == PREFERRED_MODELS;
    assert chain[len(PREFERRED_MODELS)] == "openrouter/other/model:free";
}

test "a vetted model off the free list is skipped, and another usable free model fills in" {
    listed = [free(bare(PREFERRED_MODELS[-1])), free("new/model:free"), free("paid/model")];
    assert choose_models(listed, TODAY) == [PREFERRED_MODELS[-1], "openrouter/new/model:free"];
}

test "a free model that cannot serve typed calls, is a classifier or app-only, or has expired is not used" {
    assert not usable(free("no/schema:free", ["response_format", "tools"]), TODAY);
    assert not usable(free("no/tools:free", ["structured_outputs"]), TODAY);
    assert not usable(free("nvidia/nemotron-3.5-content-safety:free"), TODAY);
    assert not usable(free("thinkingmachines/inkling:free"), TODAY);
    assert not usable(free("paid/model"), TODAY);
    assert not usable(free("old/model:free", expires="2026-11-01"), TODAY);
    assert usable(free("last/day:free", expires="2026-11-02"), TODAY);
    assert usable(free("ok/model:free"), TODAY);
}

test "the chain holds at most MAX_CHAIN models, and nothing usable gives an empty chain" {
    listed = [free(f"m{i}/model:free") for i in range(MAX_CHAIN + 3)];
    assert len(choose_models(listed, TODAY, preferred=[])) == MAX_CHAIN;
    assert choose_models([free("paid/model")], TODAY) == [];
}

test "an unreadable list, or no API key, keeps the vetted models as they are" {
    assert choose_models(None, TODAY) == PREFERRED_MODELS[:MAX_CHAIN];
    assert listed_from_fake(None) is None;
    saved = os.environ.pop("OPENROUTER_API_KEY", None);
    try {
        fake.key_requests = [];
        assert listed_models() is None;
        assert fake.key_requests == [];
    } finally {
        if saved is not None {
            os.environ["OPENROUTER_API_KEY"] = saved;
        }
    }
}

test "the list is read from OpenRouter's public models endpoint" {
    rows = [{"id": "a/b:free", "supported_parameters": ["tools"], "expiration_date": "2026-12-31"}, {"name": "no id"}];
    found = listed_from_fake(rows);
    assert found is not None;
    assert [(m.id, m.parameters, m.expires) for m in found] == [("a/b:free", ["tools"], "2026-12-31")];
    assert fake.key_requests[-1] == "";
}

test "resolving sets the shared chain and says which vetted models are missing" {
    rows = [{"id": bare(PREFERRED_MODELS[-1]), "supported_parameters": TYPED}, {"id": "new/model:free", "supported_parameters": TYPED}];
    (chain, note, shared) = resolve_from_fake(rows);
    assert chain == shared == [PREFERRED_MODELS[-1], "openrouter/new/model:free", ROUTER_MODEL];
    assert bare(PREFERRED_MODELS[0]) in note;
}

test "with nothing usable listed, the vetted models are kept and the note says so" {
    (chain, note, _) = resolve_from_fake([{"id": "paid/model", "supported_parameters": TYPED}]);
    assert chain == PREFERRED_MODELS[:MAX_CHAIN] + [ROUTER_MODEL];
    assert "no free model" in note;
}

test "the router is always last, beyond the cap, even when the list is unreadable" {
    rows = [{"id": f"m{i}/model:free", "supported_parameters": TYPED} for i in range(MAX_CHAIN + 2)];
    (chain, _, _) = resolve_from_fake(rows);
    assert len(chain) == MAX_CHAIN + 1 and chain[-1] == ROUTER_MODEL;
    (unread, _, _) = resolve_from_fake(None);
    assert unread == PREFERRED_MODELS[:MAX_CHAIN] + [ROUTER_MODEL];
}
