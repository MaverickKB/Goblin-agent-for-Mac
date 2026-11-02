import Foundation
import Testing
@testable import Goblin

@Test func preservesTypedNestedEngineFrames() throws {
    let source = #"{"id":"opaque","result":{"busy":false,"messages":[{"id":"1","kind":"agent","text":"Hello"}],"memory":{"debt":0}},"extra":null}"#
    let value = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
    #expect(value["result"]["busy"].boolValue == false)
    #expect(value["result"]["messages"].arrayValue.first?["text"].stringValue == "Hello")
    #expect(value["result"]["memory"]["debt"].numberValue == 0)
    #expect(value["missing"] == .null)
    let roundTrip = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    #expect(roundTrip == value)
}

@Test func messageIdentityComesFromAuthoritativeEngine() {
    let message = ChatMessage(.object(["id": .string("42"), "kind": .string("tool"), "name": .string("shell"), "text": .string("actual output")]))
    #expect(message.id == "42")
    #expect(message.kind == "tool")
    #expect(message.name == "shell")
    #expect(message.text == "actual output")
}
