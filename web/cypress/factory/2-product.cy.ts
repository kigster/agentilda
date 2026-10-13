// The second half of the factory test: the page the agents built in 1-build.cy.ts, served from the throwaway repository
// and played. Its own spec, so its first visit sets the origin: the control room and the product are different origins.

/** The board's nine cells, whatever the agents called them: the first selector that finds exactly nine. */
const CELLS = ["[data-cell]", "[data-index]", ".cell", ".square", "#board > *", ".board > *", "td", "button"];
const isCell = (el: HTMLElement) => !/restart|reset|new game/i.test(el.textContent ?? "");

function cells(): Cypress.Chainable<JQuery<HTMLElement>> {
  return cy.document().then((doc) => {
    const selector = CELLS.find((s) => Array.from(doc.querySelectorAll<HTMLElement>(s)).filter(isCell).length === 9);
    if (!selector) throw new Error("the page has no board of nine cells");
    return cy.get(selector).filter((_, el) => isCell(el));
  });
}

describe("the tic-tac-toe page the factory built", () => {
  it("built a page where X wins, the win is announced, and Restart clears the board", () => {
    cy.task<string | null>("findProduct", Cypress.env("projectDir")).then((file) => {
      expect(file, "index.html outside .plans").to.be.a("string");
      cy.task<string>("serveProduct", file).then((url) => cy.visit(url));
    });

    // X takes the top row while O plays the middle one.
    [0, 3, 1, 4, 2].forEach((i) => cells().eq(i).click());
    cells().eq(0).should("contain.text", "X");
    cy.get("body").invoke("prop", "innerText").should("match", /\bX\b[^.!\n]*\bwin|\bwinner\b[^.!\n]*\bX\b/i);

    cy.contains("button", /restart/i).click();
    cells().each((cell) => expect(cell.text().trim(), "an empty cell after Restart").to.eq(""));
  });
});
