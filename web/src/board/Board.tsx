import type { CSSProperties, ReactNode } from "react";
import type { Board as BoardData, Snapshot, Station } from "../api/types";
import { PlanRow, type CarHandlers } from "./PlanRow";
import { lastSeen, who } from "./format";
import { isMerged } from "./model";
import "./board.css";

/** The station columns: StateMachine::SPINE, each with the agents whose `handles:` names it. */
export function Stations({ stations }: { stations: Station[] }) {
  return (
    <div className="stations">
      <span />
      {stations.map(s => (
        <div className="station-name" key={s.key}>
          {s.label}
          <span className="station-agent">{s.agents.map(a => a.split("-")[0]).join(" + ") || " "}</span>
        </div>
      ))}
    </div>
  );
}

function Inner({ stations, children }: { stations: Station[]; children: ReactNode }) {
  return (
    <div className="board-inner" style={{ "--stations": stations.length } as CSSProperties}>
      <Stations stations={stations} />
      {children}
    </div>
  );
}

/** A band in the highlight colour opening one machine's rows in the merged board. */
export function MachineHead({ name, facts }: { name: string; facts: string[] }) {
  return (
    <div className="machine-head">
      <h2>{name}</h2>
      <p>
        {facts.map(f => (
          <span key={f}>{f}</span>
        ))}
      </p>
    </div>
  );
}

/** Their plans still on their board: merged ones left it long ago. */
const showing = (s: Snapshot) => s.plans.filter(p => !isMerged(p));

interface BoardProps extends CarHandlers {
  board: BoardData;
  /** All machines: every other machine's rows under ours, read only. */
  merged: boolean;
  /** Merged rows fading out right now. */
  retiring: ReadonlySet<string>;
  /** Merged rows that have left the board. */
  gone: ReadonlyMap<string, unknown>;
}

/** The transit board: our plans, and with All machines on, everyone else's under ours. */
export function Board({ board, merged, retiring, gone, ...cars }: BoardProps) {
  const { me, others } = board;
  const ours = me.plans.filter(p => !gone.has(p.ordinal));
  return (
    <Inner stations={me.stations}>
      {merged && <MachineHead name={who(me.node)} facts={[me.node.ip, `${ours.length} plans`, "this machine"].filter((f): f is string => f !== null)} />}
      {ours.length === 0 && !merged && <p className="board-empty">No plans in this run yet. Add one from Action.</p>}
      {ours.map(plan => (
        <PlanRow key={plan.ordinal} plan={plan} stations={me.stations} models={me.models} retiring={retiring.has(plan.ordinal)} {...cars} />
      ))}
      {merged &&
        others.map(their => (
          <MachineRows key={their.node.id} their={their} me={me} />
        ))}
    </Inner>
  );
}

function MachineRows({ their, me }: { their: Snapshot; me: Snapshot }) {
  const plans = showing(their);
  return (
    <>
      <MachineHead
        name={who(their.node)}
        facts={[their.node.ip, `${plans.length} plans`, "read only", `last seen ${lastSeen(their, me)}s ago`].filter((f): f is string => f !== null)}
      />
      {plans.map(plan => (
        <PlanRow key={plan.ordinal} plan={plan} stations={their.stations} models={their.models} owner={their.node} faded />
      ))}
    </>
  );
}

/** One other machine's board, read only, for its tab. */
export function MachineBoard({ their, me }: { their: Snapshot; me: Snapshot }) {
  return (
    <>
      <p className="machine-note">
        Read only. <strong>{who(their.node)}</strong>
        {their.node.ip ? ` (${their.node.ip})` : ""} is working on these in {their.node.checkout}; this machine will not start
        them. Last seen {lastSeen(their, me)}s ago.
      </p>
      <Inner stations={their.stations}>
        {showing(their).map(plan => (
          <PlanRow key={plan.ordinal} plan={plan} stations={their.stations} models={their.models} owner={their.node} />
        ))}
      </Inner>
    </>
  );
}
