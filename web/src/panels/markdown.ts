// Markdown to safe HTML, in the mockup's order: marked parses, DOMPurify strips anything that could run, then
// highlight.js colours each fenced block in the language its fence names. Gruvbox colours its classes (panels.css).
import { marked } from "marked";
import DOMPurify from "dompurify";
import hljs from "highlight.js/lib/common";

export function renderMarkdown(text: string): string {
  const html = marked.parse(text, { async: false, gfm: true });
  const fragment = DOMPurify.sanitize(html, { RETURN_DOM_FRAGMENT: true });
  for (const a of fragment.querySelectorAll("a")) {
    a.target = "_blank";
    a.rel = "noopener noreferrer";
  }
  for (const code of fragment.querySelectorAll("pre code")) {
    const lang = [...code.classList].find((c) => c.startsWith("language-"))?.slice(9);
    if (lang && hljs.getLanguage(lang)) {
      code.innerHTML = hljs.highlight(code.textContent ?? "", { language: lang, ignoreIllegals: true }).value;
      code.classList.add("hljs");
    }
  }
  const out = document.createElement("div");
  out.append(fragment);
  return out.innerHTML;
}
