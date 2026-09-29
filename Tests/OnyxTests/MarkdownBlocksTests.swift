import XCTest
@testable import Onyx

/// Block parser behind the notes preview — covers the constructs Claude's
/// generated notes actually contain.
final class MarkdownBlocksTests: XCTestCase {

    func test_typicalGeneratedNote() {
        let md = """
        ## Décisions
        - Recruter un alternant
        - Budget **validé**

        ## Action items
        1. Yvan : préparer la fiche de poste
        2. RH : publier l'annonce

        Contexte général sur
        deux lignes.
        """
        let blocks = MarkdownBlocks.parse(md)
        XCTAssertEqual(blocks, [
            .heading(level: 2, text: "Décisions"),
            .bullet(indent: 0, text: "Recruter un alternant"),
            .bullet(indent: 0, text: "Budget **validé**"),
            .heading(level: 2, text: "Action items"),
            .numbered(number: "1", indent: 0, text: "Yvan : préparer la fiche de poste"),
            .numbered(number: "2", indent: 0, text: "RH : publier l'annonce"),
            .paragraph(text: "Contexte général sur deux lignes."),
        ])
    }

    func test_quote_rule_andCodeFence() {
        let md = """
        > citation importante
        ---
        ```
        let x = 1
        let y = 2
        ```
        """
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .quote(text: "citation importante"),
            .rule,
            .code(text: "let x = 1\nlet y = 2"),
        ])
    }

    func test_unterminatedCodeFence_stillRenders() {
        let blocks = MarkdownBlocks.parse("```\norphan line")
        XCTAssertEqual(blocks, [.code(text: "orphan line")])
    }

    func test_hashWithoutSpace_isAParagraphNotAHeading() {
        XCTAssertEqual(MarkdownBlocks.parse("#hashtag pas un titre"),
                       [.paragraph(text: "#hashtag pas un titre")])
    }

    func test_nestedBullets_keepIndentLevel() {
        let blocks = MarkdownBlocks.parse("- parent\n  - enfant")
        XCTAssertEqual(blocks, [
            .bullet(indent: 0, text: "parent"),
            .bullet(indent: 1, text: "enfant"),
        ])
    }

    // MARK: - Tables

    func test_pipeTable_headerAndRows() {
        let md = """
        | Élément | Valeur |
        |---|---|
        | Hausse prix gaz | +90 % |
        | Trésorerie | 13–15 M€ |
        """
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .table(headers: ["Élément", "Valeur"],
                   alignments: [nil, nil],
                   rows: [["Hausse prix gaz", "+90 %"], ["Trésorerie", "13–15 M€"]]),
        ])
    }

    func test_pipeTable_alignmentMarkers() {
        let md = """
        | a | b | c | d |
        |:--|:-:|--:|---|
        | 1 | 2 | 3 | 4 |
        """
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .table(headers: ["a", "b", "c", "d"],
                   alignments: [.leading, .center, .trailing, nil],
                   rows: [["1", "2", "3", "4"]]),
        ])
    }

    func test_pipeTable_withoutOuterPipes_andRaggedRows() {
        let md = """
        a | b | c
        --- | --- | ---
        1 | 2
        1 | 2 | 3 | 4
        """
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .table(headers: ["a", "b", "c"],
                   alignments: [nil, nil, nil],
                   rows: [["1", "2", ""], ["1", "2", "3"]]),
        ])
    }

    func test_pipeTable_escapedPipeStaysInTheCell() {
        let md = """
        | a | b |
        |---|---|
        | x \\| y | z |
        """
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .table(headers: ["a", "b"], alignments: [nil, nil],
                   rows: [["x | y", "z"]]),
        ])
    }

    func test_pipeTable_endsAtBlankLine_andSurroundingBlocksSurvive() {
        let md = """
        Intro.

        | a | b |
        |---|---|
        | 1 | 2 |

        Suite.
        """
        XCTAssertEqual(MarkdownBlocks.parse(md), [
            .paragraph(text: "Intro."),
            .table(headers: ["a", "b"], alignments: [nil, nil], rows: [["1", "2"]]),
            .paragraph(text: "Suite."),
        ])
    }

    /// Column-count mismatch between header and delimiter: not a table at all.
    func test_delimiterWithWrongColumnCount_isNotATable() {
        let blocks = MarkdownBlocks.parse("| a | b |\n|---|\n| 1 | 2 |")
        XCTAssertEqual(blocks, [.paragraph(text: "| a | b | |---| | 1 | 2 |")])
    }

    /// A lone `---` after a paragraph is still a horizontal rule, not the
    /// delimiter row of a table.
    func test_ruleAfterParagraph_isStillARule() {
        XCTAssertEqual(MarkdownBlocks.parse("texte\n---\nsuite"), [
            .paragraph(text: "texte"),
            .rule,
            .paragraph(text: "suite"),
        ])
    }

    func test_tableWithNoBodyRows_stillRendersItsHeader() {
        XCTAssertEqual(MarkdownBlocks.parse("| a | b |\n|---|---|"), [
            .table(headers: ["a", "b"], alignments: [nil, nil], rows: []),
        ])
    }
}
