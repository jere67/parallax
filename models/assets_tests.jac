"""Asset classes (models/assets.jac): which class a symbol is, and a clean choice of classes."""
import from models.assets { CRYPTO, OPTIONS, STOCKS, asset_class_of, clean_classes }

test "a slash marks a coin, an OCC symbol an option, and anything else a stock" {
    assert asset_class_of("BTC/USD") == CRYPTO;
    assert asset_class_of("AAPL261218C00200000") == OPTIONS;
    assert asset_class_of("AAPL") == STOCKS and asset_class_of("BRK.B") == STOCKS;
}

test "a choice keeps known classes once, in the canonical order" {
    assert clean_classes(["us_option", "crypto", "nonsense", "crypto", "us_equity"]) == [STOCKS, CRYPTO, OPTIONS];
    assert clean_classes([]) == [];
}
