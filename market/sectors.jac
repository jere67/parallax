"""The eleven GICS sectors for any SEC filer.

S&P publishes GICS only for the index's members, which come from Wikipedia. Every other company
has an SEC industry code (SIC) instead, and this table maps that code to the sector a reader would
expect, so one sector filter covers the whole market. It is a broad mapping: a company whose
business has outgrown its code lands where the code says.
"""

glob ENERGY: str = "Energy";
glob MATERIALS: str = "Materials";
glob INDUSTRIALS: str = "Industrials";
glob DISCRETIONARY: str = "Consumer Discretionary";
glob STAPLES: str = "Consumer Staples";
glob HEALTH: str = "Health Care";
glob FINANCIALS: str = "Financials";
glob TECHNOLOGY: str = "Information Technology";
glob COMMUNICATION: str = "Communication Services";
glob UTILITIES: str = "Utilities";
glob REAL_ESTATE: str = "Real Estate";

# The sectors as a reader sees them, for the sector filter.
glob SECTORS: list[str] = [COMMUNICATION, DISCRETIONARY, STAPLES, ENERGY, FINANCIALS, HEALTH, INDUSTRIALS, TECHNOLOGY, MATERIALS, REAL_ESTATE, UTILITIES];

# Inclusive SIC ranges, narrowest first: the first range holding a code gives its sector.
glob SIC_RANGES: list[tuple[int, int, str]] = [
    (1311, 1389, ENERGY),
    (1520, 1531, DISCRETIONARY),
    (2830, 2836, HEALTH),
    (2840, 2844, STAPLES),
    (2900, 2999, ENERGY),
    (3140, 3149, DISCRETIONARY),
    (3570, 3579, TECHNOLOGY),
    (3630, 3659, DISCRETIONARY),
    (3660, 3699, TECHNOLOGY),
    (3711, 3716, DISCRETIONARY),
    (3800, 3829, TECHNOLOGY),
    (3840, 3851, HEALTH),
    (4800, 4899, COMMUNICATION),
    (4950, 4959, INDUSTRIALS),
    (5047, 5047, HEALTH),
    (5122, 5122, HEALTH),
    (5140, 5149, STAPLES),
    (5400, 5499, STAPLES),
    (5912, 5912, STAPLES),
    (6500, 6599, REAL_ESTATE),
    (6798, 6798, REAL_ESTATE),
    (7310, 7319, COMMUNICATION),
    (7370, 7379, TECHNOLOGY),
    (7990, 7999, DISCRETIONARY),
    (8731, 8731, HEALTH),
    (100, 999, STAPLES),
    (1000, 1499, MATERIALS),
    (1500, 1799, INDUSTRIALS),
    (2000, 2199, STAPLES),
    (2200, 2399, DISCRETIONARY),
    (2400, 2499, MATERIALS),
    (2500, 2599, DISCRETIONARY),
    (2600, 2699, MATERIALS),
    (2700, 2799, COMMUNICATION),
    (2800, 2899, MATERIALS),
    (3000, 3399, MATERIALS),
    (3400, 3629, INDUSTRIALS),
    (3700, 3799, INDUSTRIALS),
    (3860, 3999, DISCRETIONARY),
    (4000, 4799, INDUSTRIALS),
    (4900, 4999, UTILITIES),
    (5000, 5199, INDUSTRIALS),
    (5200, 5999, DISCRETIONARY),
    (6000, 6799, FINANCIALS),
    (7000, 7299, DISCRETIONARY),
    (7300, 7399, INDUSTRIALS),
    (7800, 7999, COMMUNICATION),
    (8000, 8099, HEALTH),
    (8200, 8299, DISCRETIONARY),
    (8300, 8999, INDUSTRIALS)
];

"""The sector for an SEC industry code, or "" for one outside the table."""
def sector_of(sic: int | None) -> str {
    if not sic {
        return "";
    }
    for (low, high, sector) in SIC_RANGES {
        if low <= sic <= high {
            return sector;
        }
    }
    return "";
}
