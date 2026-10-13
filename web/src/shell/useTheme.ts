import { useCallback, useEffect, useState } from "react";

export type Theme = "light" | "dark";

const systemDark = (): boolean => window.matchMedia("(prefers-color-scheme: dark)").matches;

/** The theme in force: the toggle's choice on <html data-theme>, else the operating system's. */
export function currentTheme(): Theme {
  const set = document.documentElement.dataset.theme;
  if (set === "light" || set === "dark") return set;
  return systemDark() ? "dark" : "light";
}

/** The theme toggle, as the mockup has it: it sets data-theme for this visit and follows the OS until pressed. */
export function useTheme(): { theme: Theme; toggle: () => void } {
  const [theme, setTheme] = useState<Theme>(currentTheme);

  useEffect(() => {
    const media = window.matchMedia("(prefers-color-scheme: dark)");
    const follow = () => setTheme(currentTheme());
    media.addEventListener("change", follow);
    return () => media.removeEventListener("change", follow);
  }, []);

  const toggle = useCallback(() => {
    const next: Theme = currentTheme() === "dark" ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    setTheme(next);
  }, []);

  return { theme, toggle };
}
