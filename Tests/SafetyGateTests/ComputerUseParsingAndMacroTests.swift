import XCTest

@testable import ComputerUse

final class ComputerUseParsingAndMacroTests: XCTestCase {
    func testParsesFunctionCallFromStepsShape() throws {
        let json = """
        {
          "id": "interaction-1",
          "steps": [
            {
              "type": "function_call",
              "name": "click",
              "args": {
                "x": 250,
                "y": 750,
                "intent": "send message"
              },
              "safety_decision": {
                "decision": "require_confirmation",
                "reason": "Sensitive send action"
              }
            }
          ]
        }
        """

        let response = try InteractionResponseParser.parse(data: Data(json.utf8))

        XCTAssertEqual(response.interactionID, "interaction-1")
        XCTAssertEqual(response.functionCalls.count, 1)
        XCTAssertEqual(response.functionCalls[0].name, "click")
        XCTAssertEqual(response.functionCalls[0].args["x"]?.doubleValue, 250)
        XCTAssertEqual(response.functionCalls[0].safetyDecision?.kind, .requireConfirmation)
    }

    func testParsesFunctionCallFromOutputsShape() throws {
        let json = """
        {
          "interaction_id": "interaction-2",
          "outputs": [
            {
              "type": "function_call",
              "function_call": {
                "name": "type",
                "arguments": {
                  "text": "Hello {{person}}"
                }
              }
            }
          ]
        }
        """

        let response = try InteractionResponseParser.parse(data: Data(json.utf8))

        XCTAssertEqual(response.interactionID, "interaction-2")
        XCTAssertEqual(response.functionCalls.count, 1)
        XCTAssertEqual(response.functionCalls[0].name, "type")
        XCTAssertEqual(response.functionCalls[0].args["text"]?.stringValue, "Hello {{person}}")
    }

    func testMacroCrystallizerFillsSlotsWithoutProviderCall() {
        let crystallizer = MacroCrystallizer()
        let action = ComputerUseAction(
            kind: .type,
            text: "Hello {{person}}",
            intent: "message {{person}}"
        )
        let macro = crystallizer.recordVerifiedSequence(
            name: "message-person",
            slotTemplate: "message {{person}}",
            slots: [MacroSlot(name: "person")],
            actions: [action]
        )

        let filled = crystallizer.fillSlots(in: macro, values: ["person": "Kuba"])

        XCTAssertEqual(filled.count, 1)
        XCTAssertEqual(filled[0].text, "Hello Kuba")
        XCTAssertEqual(filled[0].intent, "message Kuba")
    }
}
