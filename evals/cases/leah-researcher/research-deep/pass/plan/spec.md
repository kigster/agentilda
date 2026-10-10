# Filing Deadlines

Show each small business its next estimated-tax filing deadline, moved for weekends and holidays.

## What research needs to settle

1. Which deadlines apply, and where do they come from?
2. How is a deadline moved when it falls on a weekend or holiday?
3. Does the codebase already know about holidays?

## Research

### 1. Which deadlines apply

Estimated tax is due in four instalments: the 15th of April, June, September and January of the following year (https://tax.example.gov/estimated-payments, retrieved 2026-09-04). The instalment schedule is the same for sole proprietors and single-member companies; partnerships pass the obligation to their partners (https://tax.example.gov/partnerships/estimated, retrieved 2026-09-04). A state-level schedule exists for the fictional state of Westland and follows the federal dates with one exception, a January instalment due on the 31st (https://revenue.westland.example.gov/estimated, retrieved 2026-09-04).

### 2. Weekends and holidays

When a due date falls on a Saturday, Sunday or legal holiday, the deadline moves to the next business day (https://tax.example.gov/publications/deadlines#weekend-rule, retrieved 2026-09-04). Legal holidays include those observed in the capital district, which adds Emancipation Day, observed on the nearest weekday when it falls on a weekend (https://dc.example.gov/holidays, retrieved 2026-09-04). The observed-date rule is where most calendars go wrong: a holiday on a Saturday is observed on the Friday before, which does not move a Monday deadline.

### 3. What the codebase knows

`lib/calendar.rb:2` hard-codes three holidays for 2025 only. Nothing computes observed dates, and nothing knows the capital district's holiday. Running the calendar against 2026 returns no holidays at all, so every 2026 deadline would be computed as if no holiday existed.

### Contradictions

1. The draft says "weekends and holidays"; the code knows 2025 only. Production runs the code, so today every holiday-adjacent deadline in 2026 is wrong.
2. The federal page lists the January instalment as the 15th; Westland lists the 31st. Both are right for their own return, so the product must show two deadlines, not one.

### Could not settle

1. Whether the product should show Westland deadlines at all, or federal only. This is a product decision for yoda to lift.
2. Whether disaster-area postponements, which move deadlines per county, are in scope (https://tax.example.gov/disaster-relief, retrieved 2026-09-04).

> [!NOTE]
>
> [2026-09-04 11:29:20 AM PDT] [ agent: leah-researcher   status: Started, round 1 ]
> [2026-09-04 11:47:51 AM PDT] [ agent: leah-researcher   status: Completed, round 1 ]
> [2026-09-04 11:47:52 AM PDT] [ next: yoda-writer ]
