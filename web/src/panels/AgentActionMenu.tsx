// The drawer's Action menu: everything but Send message, which stays a button. It opens upward from the drawer's
// right edge, so it stays inside the drawer.
import * as Menu from "@radix-ui/react-dropdown-menu";

export type AgentAction = "hold" | "wrap_up" | "compact" | "stop";

export interface AgentActionMenuProps {
  /** Fraction of the context in use, for Compact's line; null when the adapter does not report it. */
  contextUsed: number | null;
  onAction: (kind: AgentAction) => void;
  disabled?: boolean;
}

function Item({ title, sub, onSelect, danger = false }: { title: string; sub: string; onSelect: () => void; danger?: boolean }) {
  return (
    <Menu.Item className={`menu-item${danger ? " menu-danger" : ""}`} onSelect={onSelect}>
      <span className="menu-title">{title}</span>
      <span className="menu-sub">{sub}</span>
    </Menu.Item>
  );
}

export function AgentActionMenu({ contextUsed, onAction, disabled = false }: AgentActionMenuProps) {
  const used = contextUsed === null ? "" : `; ${Math.round(contextUsed * 100)}% of its context used`;
  return (
    <Menu.Root>
      <Menu.Trigger className="btn" disabled={disabled}>Action <span aria-hidden="true">▾</span></Menu.Trigger>
      <Menu.Portal>
        <Menu.Content className="menu is-up" side="top" align="end" sideOffset={6}>
          <Item title="Hold for now" sub="Pause after its current step until you send more" onSelect={() => onAction("hold")} />
          <Item title="Wrap up" sub="Finish the current step, leave a note, then stop" onSelect={() => onAction("wrap_up")} />
          <Item title="Compact" sub={`Run /compact now${used}`} onSelect={() => onAction("compact")} />
          <Item title="Stop agent" sub="Stop now; it gets 60 seconds to leave a resume note" onSelect={() => onAction("stop")} danger />
        </Menu.Content>
      </Menu.Portal>
    </Menu.Root>
  );
}
