import type { TestRun } from "../board/model";
import { planId } from "../board/format";

/**
 * A test run's tab. The contract has no test stream yet (W15), so this reads only what the car's activity line says:
 * the command and how far it has got. Passed, failed and pending counts, the failures and the output arrive with it.
 */
export function TestsPanel({ run }: { run: TestRun }) {
  const pct = run.total ? Math.round((run.done / run.total) * 100) : 0;
  return (
    <>
      <div className="tests-head">
        <h2>
          {planId(run.plan.ordinal)} {run.plan.title}: tests
        </h2>
        <p>
          {run.car.agent} ran <code>{run.cmd}</code>. Still running.
        </p>
      </div>
      <div className="tests-stats" aria-live="polite">
        <div>
          Run<strong>{run.done}</strong>
        </div>
        <div>
          Of<strong>{run.total}</strong>
        </div>
      </div>
      <div className="bar" role="progressbar" aria-label="Examples run" aria-valuemin={0} aria-valuemax={100} aria-valuenow={pct}>
        <span className="run" style={{ width: `${pct}%` }} />
      </div>
    </>
  );
}
