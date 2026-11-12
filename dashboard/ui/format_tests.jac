"""The dashboard's number and time formats (dashboard/ui/format.jac)."""
import from dashboard.ui.format {
    compact,
    day_long,
    day_year,
    gate_label,
    order_label,
    source_time,
    stamp_long_et,
    day_short,
    money,
    num,
    pct,
    qty,
    count,
    signed,
    signed_money,
    signed_pct,
    stamp_et,
    time_et,
    time_range_et,
    tone
}

test "numbers group thousands and carry a sign only where a change is meant" {
    assert money(1234567.891) == "$1,234,567.89" and money(-0.004) == "$0.00" and money(-12.5) == "-$12.50";
    assert signed_money(250.0) == "+$250.00" and signed_money(-1234.5) == "-$1,234.50" and signed_money(0.001) == "$0.00";
    assert pct(0.01234) == "1.23%" and signed_pct(-0.00421) == "-0.42%" and signed_pct(0.0) == "0.00%";
    assert num(1234.5, 1) == "1,234.5" and num(-0.04, 1) == "0.0";
    assert num(100.0, 0) == "100" and qty(12500) == "12,500" and signed(0.4321) == "+0.43";
    assert count(1, "order") == "1 order" and count(0, "order") == "0 orders" and count(1200, "share") == "1,200 shares";
    assert compact(52300000.0) == "52.3M" and compact(840000.0) == "840K" and compact(None) == "-";
    assert money(None) == "-" and pct(None) == "-" and tone(None) == "text-muted";
    assert tone(0.1) == "text-up" and tone(-0.1) == "text-down" and tone(0.0) == "text-muted";
}

test "dates and times read in New York time, across daylight saving" {
    assert day_short("2026-10-21") == "Oct 21" and day_long("2026-10-21") == "Wed, Oct 21, 2026";
    assert day_long("2026-11-02") == "Mon, Nov 2, 2026" and day_short("") == "-";
    assert time_et("2026-10-21T20:30:00+00:00") == "4:30 PM ET";
    assert time_et("2026-11-02T14:45:00+00:00") == "9:45 AM ET";
    assert stamp_et("2026-10-22T02:15:00+00:00") == "Oct 21, 10:15 PM ET";
    assert stamp_et("2026-01-01T03:00:00+00:00") == "Dec 31, 10:00 PM ET";
    assert time_et("2026-03-08T07:30:00+00:00") == "3:30 AM ET" and time_et("2026-03-08T06:30:00+00:00") == "1:30 AM ET";
    assert time_range_et("2026-10-21T11:30:00+00:00", "2026-10-21T12:40:00+00:00") == "7:30 - 8:40 AM ET";
    assert time_range_et("2026-10-21T15:30:00+00:00", "2026-10-21T16:10:00+00:00") == "11:30 AM - 12:10 PM ET";
    assert time_range_et("2026-10-21T11:30:00+00:00", "") == "7:30 AM ET" and time_range_et("", "") == "-";
}

test "a source's time carries its year, and a bare date stays a date" {
    assert day_year("2026-10-21") == "Oct 21, 2026" and day_year("") == "-";
    assert stamp_long_et("2025-12-31T21:05:00+00:00") == "Dec 31, 2025, 4:05 PM ET" and stamp_long_et("") == "-";
    assert source_time("2026-10-20T13:05:00Z", "2026-10-20T13:05:00+00:00") == "Oct 20, 2026, 9:05 AM ET";
    assert source_time("2026-08-14") == "Aug 14, 2026" and source_time("") == "-";
}

test "a blocked gate, an order never sent, and a broker's refusal read differently" {
    assert gate_label("rejected") == "Gate blocked" and gate_label("approved") == "Approved" and gate_label("resized") == "Resized";
    assert order_label("rejected", "insufficient buying power") == "Broker rejected";
    assert order_label("rejected", "not sent: its stop filled (5 shares) before the order") == "Not sent";
    assert order_label("filled") == "" and order_label("pending_new") == "";
    assert gate_label("rejected") != order_label("rejected");
}
