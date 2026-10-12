# Equipment Market Signals

Do input costs and interest rates lead construction equipment prices? A small analytics project built in Snowflake using public data only.

This shows my approach to a pricing-analytics question. It does not reflect any company's actual pricing.

## Question

Which cost and demand signals move with construction equipment prices, and with what delay?

## Data (public, monthly, Jan 1993 to Aug 2026)

All series come from FRED (BLS and Census data):

- Producer Price Index by Industry: Construction Machinery Manufacturing (price proxy, series PCU333120333120)
- Producer Price Index by Commodity: Metals and Metal Products: Steel Mill Products (input cost, series WPU1017)
- Total Construction Spending (demand proxy)
- Federal Funds Effective Rate, monthly (financing cost)

## Method

1. Loaded the raw CSVs into Snowflake (`EQUIP_SIGNALS.RAW`).
2. Joined them into one monthly table and converted each series to year-over-year change, so shared long-term trends do not create false correlations (`EQUIP_SIGNALS.CLEAN`).
3. Used window functions to lag each signal and `CORR()` to compare it with machinery price changes, across all months and since 2015 (about 140 months).
4. Computed steel's correlation at every lead time from 0 to 24 months.
5. Stress-tested the main result by excluding 2020 to 2024.

**Data-quality note:** my first steel series had missing months, which cut its usable history by more than half. I caught it because its month count was far below the other series, and replaced it with a complete series.

## Findings

1. **Steel price changes lead machinery price changes by roughly a year.** Correlation is about 0.16 in the same month, 0.50 at 6 months, and peaks near 0.62 at 12 to 14 months, with nearly identical results in both time windows. Excluding 2020 to 2024, the 12-month correlation is 0.45, so the relationship holds in normal conditions but is strongest during large cost shocks.
2. **Interest rate changes move with machinery prices at the same time, not ahead of them** (0.39 same month, 0.60 since 2015, fading to 0.26 at 6 months). Both rose together in the recent inflation cycle, so I read this as a shared cycle, not rates driving prices.
3. **Construction spending is a weak signal** (0.17 to 0.23 across all months, 0.25 to 0.31 since 2015).

## Limits

Correlation is not causation. National PPI is a proxy for pricing, not company data. Year-over-year windows in neighboring months overlap, so correlations look more certain than they are. Construction spending is in nominal dollars.

## Next steps

Test product-line and regional pricing instead of one national index, add dealer and competitor data, adjust spending for inflation, and move from correlations to a model with controls.

## Files

- `analysis.sql`: all SQL, in the order it was run
- `charts/chart1_machinery_vs_steel.png`: machinery vs. steel year-over-year change, standardized, steel shown 12 months earlier
- `charts/chart2_correlation_by_lag.png`: correlation by steel lead time
- `summary.pdf`: one-page summary
