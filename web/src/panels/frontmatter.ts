// The frontmatter the idea dialog sets for every plan its idea becomes; Plans::Spec owns the vocabulary.
export interface IdeaFrontmatter {
  lane: "full" | "plan" | "quick";
  research: boolean;
  frontend: "auto" | "true" | "false";
  depth: "auto" | "fast" | "medium" | "deep";
}

export const IDEA_DEFAULTS: IdeaFrontmatter = { lane: "full", research: false, frontend: "auto", depth: "auto" };
