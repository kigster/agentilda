// Needs you: the rail of questions agents asked. Answering in words, answering yes or no, and holding one blocked.
describe("Needs you", () => {
  beforeEach(() => cy.openBoard());

  it("answers a question in words", () => {
    cy.get('.rail [data-ask="001.00/B1"]').within(() => {
      cy.get("textarea").type("Yes, carry the checkout id in every key.");
      cy.contains("button", "Send answer").click();
    });
    cy.get('.rail [data-ask="001.00/B1"]').should("contain", "Answer sent to");
    cy.boardEventually((me) => me.plans.find((p) => p.ordinal === "001.00")?.questions.length === 0);
  });

  it("answers a yes or no question with one click", () => {
    cy.get('.rail [data-ask="006.00/B1"]').within(() => {
      cy.contains("button", "Yes").click();
    });
    cy.get('.rail [data-ask="006.00/B1"]').should("contain", "Answered yes to");
    cy.boardEventually((me) => me.plans.find((p) => p.ordinal === "006.00")?.questions.length === 0);
  });

  it("holds a question blocked, which takes it off the rail", () => {
    cy.get('.rail [data-ask="001.00/B1"]').within(() => {
      cy.contains("button", "Hold blocked").click();
    });
    cy.get('.rail [data-ask="001.00/B1"]').should("not.exist");
    cy.boardEventually((me) => me.plans.find((p) => p.ordinal === "001.00")?.questions[0]?.held === true);
  });
});
