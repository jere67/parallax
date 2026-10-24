# 13F fixture provenance

The four INFOTABLE rows are transcribed from Beese Fulmer Investment Management's SEC information table, accession 0000911274-26-000003, for March 31, 2026, filed April 16, 2026:
https://www.sec.gov/Archives/edgar/data/911274/000091127426000003/xslForm13F_X02/2026Q113F.xml
The filing index confirms the dates and manager CIK:
https://www.sec.gov/Archives/edgar/data/911274/000091127426000003/0000911274-26-000003-index.htm

These are a small reconstruction in the SEC bulk TSV schema, not an untouched recording of a downloaded bulk ZIP.
The SEC ZIP endpoints returned HTTP 403 from the development environment.
Headers follow https://www.sec.gov/files/form_13f_readme.pdf; unused columns are omitted.
Tests package these readable TSVs into a ZIP and replay that binary response through SourceClient and FakeSource.
The other ZIPs in holdings_tests.jac are synthetic cases for amendments, options, shared discretion, invalid responses, and quarter comparisons; their small numbers are deliberately distinct from recorded figures.

The modern download links used by the tests were verified against the SEC's Form 13F Data Sets listing on October 23, 2026:
https://www.sec.gov/data-research/sec-markets-data/form-13f-data-sets
They cover March-May 2026 and June-August 2026 filing windows, respectively, not the holdings periods themselves.
