import XCTest

@testable import Dictate_Anywhere

final class AssemblyAIEngineTests: XCTestCase {
    func testRegionsUseDocumentedHosts() {
        XCTAssertEqual(AssemblyAIRegion.global.baseURL.host, "dictation.assemblyai.com")
        XCTAssertEqual(AssemblyAIRegion.unitedStates.baseURL.host, "dictation.us.assemblyai.com")
        XCTAssertEqual(AssemblyAIRegion.europeanUnion.baseURL.host, "dictation.eu.assemblyai.com")
    }

    func testLanguageCatalogContainsUniqueDocumentedCodes() {
        XCTAssertEqual(AssemblyAILanguage.allCases.count, 32)
        XCTAssertEqual(Set(AssemblyAILanguage.allCases.map(\.rawValue)).count, 32)
        XCTAssertTrue(AssemblyAILanguage.allCases.contains(.english))
        XCTAssertTrue(AssemblyAILanguage.allCases.contains(.mandarin))
        XCTAssertTrue(AssemblyAILanguage.allCases.contains(.cantonese))
    }

    func testKeytermsAreTrimmedDeduplicatedAndBounded() {
        let terms = AssemblyAIEngine.fittedKeyterms([
            "  Dictate Anywhere  ", "dictate anywhere", "AssemblyAI", "", "AssemblyAI",
        ])
        XCTAssertEqual(terms, ["Dictate Anywhere", "AssemblyAI"])

        let manyTerms = (0..<150).map { "Term\($0)" }
        XCTAssertEqual(AssemblyAIEngine.fittedKeyterms(manyTerms)?.count, 100)
    }

    func testLivePreviewVocabularyCombinesPersistentAndContextualTerms() {
        XCTAssertEqual(
            AssemblyAIEngine.livePreviewVocabulary(
                customVocabulary: ["Dictate Anywhere", "AssemblyAI"],
                contextualVocabulary: ["assemblyai", "Roadmap"]
            ),
            ["Dictate Anywhere", "AssemblyAI", "Roadmap"]
        )
    }

    func testFinalTextUsesPolishedResponseAndFallsBackToVerbatim() {
        let polished = AssemblyAIDictationResponse(
            text: " um hello ",
            llmResponse: " Hello.",
            llmError: nil,
            requestTimeMilliseconds: 320
        )
        XCTAssertEqual(AssemblyAIEngine.finalText(from: polished, outputMode: .polished), "Hello.")
        XCTAssertEqual(AssemblyAIEngine.finalText(from: polished, outputMode: .verbatim), "um hello")

        let failedRewrite = AssemblyAIDictationResponse(
            text: "Original text",
            llmResponse: nil,
            llmError: "timeout",
            requestTimeMilliseconds: nil
        )
        XCTAssertEqual(
            AssemblyAIEngine.finalText(from: failedRewrite, outputMode: .polished),
            "Original text"
        )
    }

    func testResponseDecodesFractionalRequestTime() throws {
        let response = try JSONDecoder().decode(
            AssemblyAIDictationResponse.self,
            from: Data(
                #"{"text":"Hello","llm_response":"Hello.","llm_error":null,"request_time_ms":134.7}"#.utf8
            )
        )

        XCTAssertEqual(response.requestTimeMilliseconds, 134.7)
    }

    func testContextPromptDoesNotExposeAppNameWithoutSharingPermission() {
        let context = makeContext()
        XCTAssertEqual(
            AssemblyAIEngine.sttPrompt(context: context, includeAppMetadata: false),
            "Dictation for a work messaging field."
        )
        XCTAssertEqual(
            AssemblyAIEngine.sttPrompt(context: context, includeAppMetadata: true),
            "Dictation for a work messaging field in Example Chat."
        )
    }

    func testRecognitionPromptSupportsCustomizedTemplates() {
        let context = makeContext()
        let overrides = [
            AssemblyAIInternalPrompt.recognitionContextWithApp.rawValue:
                "Capture {category} wording for {app}."
        ]

        XCTAssertEqual(
            AssemblyAIEngine.sttPrompt(
                context: context,
                includeAppMetadata: true,
                promptOverrides: overrides
            ),
            "Capture work messaging wording for Example Chat."
        )
    }

    func testLLMInstructionIncludesNearbyTextOnlyWhenOptedIn() {
        let context = makeContext()
        let privateInstruction = AssemblyAIEngine.llmInstruction(
            customInstruction: "Keep it concise.",
            context: context,
            shareSurroundingText: false,
            style: .casual
        )
        XCTAssertFalse(privateInstruction.contains("Confidential roadmap"))
        XCTAssertTrue(privateInstruction.contains("Keep it concise."))

        let sharedInstruction = AssemblyAIEngine.llmInstruction(
            customInstruction: "Keep it concise.",
            context: context,
            shareSurroundingText: true,
            style: .casual
        )
        XCTAssertTrue(sharedInstruction.contains("Confidential roadmap"))
    }

    func testMissingCursorDataDoesNotRequestModelBoundarySpacing() {
        let missing = makeContext(before: nil, after: nil)
        XCTAssertFalse(AssemblyAIEngine.canRequestInsertionPlan(context: missing, shareSurroundingText: true))
        let prompt = AssemblyAIEngine.llmInstruction(
            customInstruction: "", context: missing, shareSurroundingText: true, style: .formal
        )
        XCTAssertFalse(prompt.contains("NEARBY DATA:"))
        XCTAssertFalse(prompt.contains("space_before"))
        XCTAssertFalse(AssemblyAIEngine.canRequestInsertionPlan(
            context: makeContext(before: "apples,", after: nil), shareSurroundingText: true
        ))
        XCTAssertFalse(AssemblyAIEngine.canRequestInsertionPlan(
            context: makeContext(), shareSurroundingText: false
        ))
    }

    func testKnownEmptyEditorCanRequestModelBoundarySpacing() {
        XCTAssertTrue(AssemblyAIEngine.canRequestInsertionPlan(
            context: makeContext(before: "", after: ""), shareSurroundingText: true
        ))
    }

    func testProseRejectsFragmentedRotationPlanAndUsesRawSentences() {
        let raw = "Snapping for rotation in this app is reversed. For everything else, I have to hold down Shift to snap. For rotation, I have to hold down Shift to stop snapping."
        let response = AssemblyAIDictationResponse(text: raw,
            llmResponse: #"{"items":["snapping","for rotation","in this app","is reversed","everything else","I have to hold down Shift to snap","the rotation","is reversed","I have to hold down Shift to release the snap or stop snapping"],"space_before":false,"space_after":false}"#,
            llmError: nil, requestTimeMilliseconds: nil)
        let context = makeContext(before: "", after: "")
        let allowsItems = AssemblyAIEngine.allowsEnumeratedItems(context: context)
        XCTAssertFalse(allowsItems)
        XCTAssertNil(ModelInsertionPlan.decode(response.llmResponse!, allowsEnumeratedItems: allowsItems))
        let text = AssemblyAIEngine.finalText(from: response, outputMode: .polished,
            requiresInsertionPlan: true, allowsEnumeratedItems: allowsItems)
        XCTAssertEqual(text, raw)
        let insertion = TextInserter().preparedTextForInsertion(text, targetBundleIdentifier: context.bundleIdentifier,
            targetProcessIdentifier: context.processIdentifier, context: context, style: .original, knownTerms: [])
        XCTAssertEqual(insertion, raw)
    }

    func testProsePromptUsesTextAndOnlyAppliesLowercasingInsideSentence() {
        for context in [makeContext(before: "", after: ""), makeContext(before: "Previous sentence. ", after: "")] {
            let prompt = AssemblyAIEngine.llmInstruction(customInstruction: "", context: context,
                shareSurroundingText: true, style: .original)
            XCTAssertTrue(prompt.contains("ACTIVE DESTINATION: PROSE"))
            XCTAssertTrue(prompt.contains(#"{"text":"#))
            XCTAssertFalse(prompt.contains(#"{"items":"#))
            XCTAssertFalse(prompt.contains("MID-SENTENCE:"))
        }
        let prompt = AssemblyAIEngine.llmInstruction(customInstruction: "", context: makeContext(before: "This is ", after: " today."),
            shareSurroundingText: true, style: .original)
        XCTAssertTrue(prompt.contains("MID-SENTENCE:"))
    }

    func testOnlyListAndInlineSeriesAllowItems() {
        XCTAssertTrue(AssemblyAIEngine.allowsEnumeratedItems(context: makeContext(before: "- Apples\n- ", after: "\n- Oranges")))
        let inline = makeContext(before: "Fruit: apples, ", after: "oranges.")
        XCTAssertTrue(AssemblyAIEngine.allowsEnumeratedItems(context: inline))
        XCTAssertFalse(AssemblyAIEngine.allowsEnumeratedItems(context: makeContext(before: "", after: "")))
        XCTAssertFalse(AssemblyAIEngine.allowsEnumeratedItems(context: makeContext(before: nil, after: nil)))
        let search = makeContext(before: "Fruit: apples, ", after: "oranges.", fieldPurpose: .searchQuery)
        XCTAssertFalse(AssemblyAIEngine.allowsEnumeratedItems(context: search))
    }

    func testProsePreservesParagraphsAndExplicitListsWithinText() throws {
        for text in ["First paragraph.\n\nSecond paragraph.", "Shopping list:\n- Apples\n- Oranges"] {
            let json = try JSONSerialization.data(withJSONObject: [
                "text": text, "space_before": false, "space_after": false
            ])
            let plan = try XCTUnwrap(ModelInsertionPlan.decode(String(decoding: json, as: UTF8.self)))
            XCTAssertEqual(plan.text, text)
        }
    }

    func testInsertionPromptPreservesCursorSidesAndLayoutAsSeparateData() throws {
        var context = makeContext()
        context.richTextContext = "• Apples\n• Bananas\n• \n• Oranges"
        let prompt = AssemblyAIEngine.llmInstruction(
            customInstruction: "", context: context, shareSurroundingText: true, style: .formal
        )
        let json = try XCTUnwrap(prompt.components(separatedBy: "NEARBY DATA:\n").last?.components(separatedBy: "\n").first)
        let nearby = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        XCTAssertEqual(nearby["before_cursor"], context.textBeforeCursor)
        XCTAssertEqual(nearby["after_cursor"], context.textAfterCursor)
        XCTAssertEqual(nearby["layout_reference"], context.richTextContext)
        XCTAssertTrue(prompt.contains("space_before"))
        XCTAssertTrue(prompt.contains("The insertion is inside an existing sentence"))
    }

    func testInsertionPromptKeepsValidDataUnderLongCustomInstructions() throws {
        var context = makeContext()
        context.richTextContext = String(repeating: "• quoted \"item\"\n", count: 200)
        let prompt = AssemblyAIEngine.llmInstruction(
            customInstruction: String(repeating: "custom ", count: 500), context: context,
            shareSurroundingText: true, style: .formal,
            promptOverrides: [AssemblyAIInternalPrompt.baseCleanup.rawValue: String(repeating: "base", count: 1000)]
        )
        XCTAssertLessThanOrEqual(prompt.count, 2048)
        let json = try XCTUnwrap(prompt.components(separatedBy: "NEARBY DATA:\n").last?.components(separatedBy: "\n").first)
        let nearby = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String])
        XCTAssertNotNil(nearby["before_cursor"])
        XCTAssertNotNil(nearby["after_cursor"])
    }

    func testStructuredPolishedOutputReturnsOnlyDictationText() throws {
        let response = AssemblyAIDictationResponse(
            text: "Strawberries.", llmResponse: #"{"text":"Strawberries","space_before":false,"space_after":false}"#,
            llmError: nil, requestTimeMilliseconds: nil
        )
        XCTAssertEqual(AssemblyAIEngine.finalText(from: response, outputMode: .polished), "Strawberries")
        XCTAssertEqual(AssemblyAIEngine.finalText(from: response, outputMode: .verbatim), "Strawberries.")
        XCTAssertNil(ModelInsertionPlan.decode(#"{"text":"Strawberries"}"#))
        XCTAssertNil(ModelInsertionPlan.decode(#"{"text":" ","space_before":false,"space_after":false}"#))
    }

    func testMalformedModelPlanNeverGetsPastedAsJSON() {
        let response = AssemblyAIDictationResponse(
            text: "Strawberries.", llmResponse: #"{"text":"Strawberries","space_before":"no"}"#,
            llmError: nil, requestTimeMilliseconds: nil
        )
        XCTAssertEqual(AssemblyAIEngine.finalText(
            from: response, outputMode: .polished, requiresInsertionPlan: true
        ), "Strawberries.")
    }

    func testEnumeratedModelPlanRetainsSemanticItemsInOrder() throws {
        let plan = try XCTUnwrap(ModelInsertionPlan.decode(
            #"{"items":["Macaroni and cheese","Sourdough starter"],"space_before":false,"space_after":false}"#,
            allowsEnumeratedItems: true
        ))
        XCTAssertEqual(plan.text, "Macaroni and cheese\nSourdough starter")
        XCTAssertEqual(plan.insertionText, plan.text)
        XCTAssertNil(ModelInsertionPlan.decode(#"{"items":["Bread", " "],"space_before":false,"space_after":false}"#, allowsEnumeratedItems: true))
        XCTAssertNil(ModelInsertionPlan.decode(#"{"items":"Bread, milk","space_before":false,"space_after":false}"#, allowsEnumeratedItems: true))
        XCTAssertNil(ModelInsertionPlan.decode(#"{"items":[],"space_before":false,"space_after":false}"#, allowsEnumeratedItems: true))
        XCTAssertNil(ModelInsertionPlan.decode(#"{"items":["Bread\nMilk"],"space_before":false,"space_after":false}"#, allowsEnumeratedItems: true))
        XCTAssertNil(ModelInsertionPlan.decode(#"{"text":"Bread","items":["Milk"],"space_before":false,"space_after":false}"#, allowsEnumeratedItems: true))
    }

    func testContextualFormalPromptDoesNotForceSentencesOntoListFragments() {
        let prompt = AssemblyAIEngine.llmInstruction(
            customInstruction: "", context: makeContext(before: "- Apples\n- ", after: "\n- Oranges"),
            shareSurroundingText: true, style: .formal
        )
        XCTAssertTrue(prompt.contains("Match neighboring capitalization AND terminal punctuation"))
        XCTAssertTrue(prompt.contains("NO final period"))
        XCTAssertTrue(prompt.contains("Compound names/descriptions stay together"))
        XCTAssertTrue(prompt.contains("insertion rules override conflicting tone"))
        XCTAssertLessThanOrEqual(prompt.count, 2048)
    }

    func testLLMInstructionReusesDestinationFormattingRules() {
        let context = makeContext(category: .email)
        let instruction = AssemblyAIEngine.llmInstruction(
            customInstruction: "Keep action items as bullets.",
            context: context,
            shareSurroundingText: false,
            style: .formal
        )

        XCTAssertTrue(instruction.contains("USER INSTRUCTIONS"))
        XCTAssertTrue(instruction.contains("Keep action items as bullets."))
        XCTAssertTrue(instruction.contains("Category: Email"))
        XCTAssertTrue(instruction.contains("EMAIL LAYOUT"))
        XCTAssertTrue(instruction.contains("greeting on its own line"))
        XCTAssertTrue(instruction.contains("Style: Formal"))
        XCTAssertTrue(instruction.contains("inside an existing sentence"))
        XCTAssertTrue(instruction.contains("Do not add terminal sentence punctuation"))
        XCTAssertLessThanOrEqual(instruction.count, 2_048)
        XCTAssertFalse(instruction.contains("Confidential roadmap"))
    }

    func testLLMInstructionUsesCustomizedDestinationAndStylePrompts() {
        let overrides = [
            AssemblyAIInternalPrompt.baseCleanup.rawValue: "Clean obvious speech artifacts.",
            AssemblyAIInternalPrompt.email.rawValue: "Use compact email paragraphs.",
            AssemblyAIInternalPrompt.formal.rawValue: "Use a precise professional voice.",
        ]
        let instruction = AssemblyAIEngine.llmInstruction(
            customInstruction: "",
            context: makeContext(category: .email),
            shareSurroundingText: false,
            style: .formal,
            promptOverrides: overrides
        )

        XCTAssertTrue(instruction.contains("Clean obvious speech artifacts."))
        XCTAssertTrue(instruction.contains("Use compact email paragraphs."))
        XCTAssertTrue(instruction.contains("Use a precise professional voice."))
        XCTAssertFalse(instruction.contains("EMAIL LAYOUT"))
        XCTAssertTrue(instruction.contains("PROTECTED OUTPUT RULES"))
    }

    func testPromptDefaultsMatchConfiguredAssemblyAIBehavior() {
        XCTAssertEqual(AssemblyAIInternalPrompt.baseCleanup.defaultValue, "")
        XCTAssertTrue(
            AssemblyAIInternalPrompt.email.defaultValue.contains("greeting on its own line")
        )
        XCTAssertEqual(
            AssemblyAIInternalPrompt.casual.defaultValue,
            DictationWritingStyle.casual.cleanupInstruction
        )
        XCTAssertEqual(AssemblyAIInternalPrompt.workMessaging.defaultValue, "")
        XCTAssertEqual(AssemblyAIInternalPrompt.personalMessaging.defaultValue, "")
        XCTAssertEqual(AssemblyAIInternalPrompt.other.defaultValue, "")

        XCTAssertFalse(AssemblyAIInternalPrompt.baseCleanup.hasBuiltInDefault)
        XCTAssertTrue(AssemblyAIInternalPrompt.email.hasBuiltInDefault)
        XCTAssertFalse(AssemblyAIInternalPrompt.workMessaging.hasBuiltInDefault)
        XCTAssertFalse(AssemblyAIInternalPrompt.personalMessaging.hasBuiltInDefault)
        XCTAssertFalse(AssemblyAIInternalPrompt.other.hasBuiltInDefault)
    }

    func testMultipartBodyPlacesConfigBeforePCM() throws {
        let config = AssemblyAIRequestConfiguration(
            sampleRate: 16_000,
            channels: 1,
            languageCodes: ["en"],
            sttPrompt: nil,
            keytermsPrompt: ["AssemblyAI"],
            llmInstruction: nil
        )
        let body = try AssemblyAIEngine.multipartBody(
            config: config,
            pcmAudio: Data([0x01, 0x02]),
            boundary: "boundary"
        )
        let rendered = String(decoding: body, as: UTF8.self)
        let configRange = try XCTUnwrap(rendered.range(of: "name=\"config\""))
        let audioRange = try XCTUnwrap(rendered.range(of: "name=\"audio\""))
        XCTAssertLessThan(configRange.lowerBound, audioRange.lowerBound)
        XCTAssertTrue(rendered.contains("\"sample_rate\":16000"))
        XCTAssertTrue(rendered.hasSuffix("\r\n--boundary--\r\n"))
    }

    func testPCMConversionClampsAndUsesSigned16BitSamples() {
        let data = AssemblyAIEngine.pcm16Data(from: [-2, -1, 0, 1, 2])
        let values = data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Int16.self)).map { Int16(littleEndian: $0) }
        }
        XCTAssertEqual(values, [Int16.min + 1, Int16.min + 1, 0, Int16.max, Int16.max])
    }

    private func makeContext(
        category: DictationContextCategory = .workMessaging,
        before: String? = "Confidential roadmap", after: String? = "Next quarter",
        fieldPurpose: DictationFieldPurpose = .unknown
    ) -> DictationContext {
        DictationContext(
            processIdentifier: 123,
            bundleIdentifier: "com.example.chat",
            appName: "Example Chat",
            category: category,
            documentURL: nil,
            documentTitle: "Roadmap",
            fieldRole: "AXTextArea",
            fieldSubrole: nil,
            fieldPurpose: fieldPurpose,
            textBeforeCursor: before,
            selectedText: nil,
            textAfterCursor: after,
            isSecureField: false,
            isContextExcluded: false
        )
    }
}
