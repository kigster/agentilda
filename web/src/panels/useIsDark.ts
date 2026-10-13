// Whether the page is dark: data-theme on <html> when someone chose, the system's preference otherwise.
import { useSyncExternalStore } from "react";

const QUERY = "(prefers-color-scheme: dark)";

function isDark(): boolean {
  const chosen = document.documentElement.dataset.theme;
  if (chosen) return chosen === "dark";
  return window.matchMedia(QUERY).matches;
}

function subscribe(onChange: () => void): () => void {
  const media = window.matchMedia(QUERY);
  media.addEventListener("change", onChange);
  const observer = new MutationObserver(onChange);
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
  return () => {
    media.removeEventListener("change", onChange);
    observer.disconnect();
  };
}

export const useIsDark = (): boolean => useSyncExternalStore(subscribe, isDark, () => false);
