import { useState, type ReactNode } from "react";
import { AskStore, StoreContext } from "./asks";

/** Optional: gives a subtree its own store. Without it every panel shares one for the page. */
export function AsksProvider({ children, store }: { children: ReactNode; store?: AskStore }) {
  const [own] = useState(() => store ?? new AskStore());
  return <StoreContext.Provider value={own}>{children}</StoreContext.Provider>;
}
