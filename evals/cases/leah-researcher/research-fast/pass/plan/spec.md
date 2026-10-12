# Billing Retries

Jobs that call the Example Corp billing API fail on transient 503 responses. Retry them.

## What research needs to settle

1. Does the repository already have a retry helper we can reuse?
2. What backoff does the billing API ask clients to use?

## Research

1. Yes. `lib/retry_policy.rb:1` defines `RetryPolicy`: three attempts, 0.5 s base, doubling. `BillingClient#charge` (`lib/billing_client.rb:2`) does not use it yet.
2. The billing API asks for exponential backoff starting at 500 ms and honouring `Retry-After` on 503 (https://docs.example.com/billing/errors, retrieved 2026-09-04). The existing policy matches except for `Retry-After`.

### Could not settle

1. Whether `charge` is idempotent on retry; the API docs do not say.

> [!NOTE]
>
> [2026-09-04 11:29:20 AM PDT] [ agent: leah-researcher   status: Started, round 1 ]
> [2026-09-04 11:31:42 AM PDT] [ agent: leah-researcher   status: Completed, round 1 ]
> [2026-09-04 11:31:43 AM PDT] [ next: yoda-writer ]
