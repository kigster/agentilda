// The page's announcer, and a command's outcome shown in place, where the mockup shows it.
import { useState, type ReactNode } from "react";
import { AnnouncerContext, type Outcome } from "./command";

/** One polite live region for the whole page. Panels inside it announce through it rather than through their own. */
export function AnnouncerProvider({ children }: { children: ReactNode }) {
  const [text, setText] = useState("");
  return (
    <AnnouncerContext.Provider value={setText}>
      {children}
      <p className="sr-only" aria-live="polite" data-testid="announcer">{text}</p>
    </AnnouncerContext.Provider>
  );
}

/** The outcome in place. It is its own live region only when no page-wide announcer would say it already. */
export function Feedback({ outcome, announced }: { outcome: Outcome | null; announced: boolean }) {
  return (
    <p className={`feedback${outcome?.tone === "refused" ? " is-refused" : ""}`} aria-live={announced ? undefined : "polite"}>
      {outcome?.text ?? ""}
    </p>
  );
}
