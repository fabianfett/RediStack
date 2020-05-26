#if !canImport(ObjectiveC)
import XCTest

extension RESPTranslatorTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__RESPTranslatorTests = [
        ("testParsing_array_nested", testParsing_array_nested),
        ("testParsing_array_recursively", testParsing_array_recursively),
        ("testParsing_array_whenEmpty", testParsing_array_whenEmpty),
        ("testParsing_array_whenNull", testParsing_array_whenNull),
        ("testParsing_array_withMixedTypes", testParsing_array_withMixedTypes),
        ("testParsing_array_withNullElements", testParsing_array_withNullElements),
        ("testParsing_arrays_chunked", testParsing_arrays_chunked),
        ("testParsing_arrays", testParsing_arrays),
        ("testParsing_bulkString_invalidNegativeSize", testParsing_bulkString_invalidNegativeSize),
        ("testParsing_bulkString_missingEndings", testParsing_bulkString_missingEndings),
        ("testParsing_bulkString_null", testParsing_bulkString_null),
        ("testParsing_bulkString_rawBytes", testParsing_bulkString_rawBytes),
        ("testParsing_bulkString_recursively", testParsing_bulkString_recursively),
        ("testParsing_bulkString_SizeIsNaN", testParsing_bulkString_SizeIsNaN),
        ("testParsing_bulkString_sizeMismatch", testParsing_bulkString_sizeMismatch),
        ("testParsing_bulkString_withContent", testParsing_bulkString_withContent),
        ("testParsing_bulkString_withNoSize", testParsing_bulkString_withNoSize),
        ("testParsing_bulkStrings_chunked", testParsing_bulkStrings_chunked),
        ("testParsing_bulkStrings", testParsing_bulkStrings),
        ("testParsing_error", testParsing_error),
        ("testParsing_integer_chunked", testParsing_integer_chunked),
        ("testParsing_integer_missingBytes", testParsing_integer_missingBytes),
        ("testParsing_integer_nonBase10", testParsing_integer_nonBase10),
        ("testParsing_integer_recursively", testParsing_integer_recursively),
        ("testParsing_integer_withAllBytes", testParsing_integer_withAllBytes),
        ("testParsing_integer", testParsing_integer),
        ("testParsing_invalidSymbols", testParsing_invalidSymbols),
        ("testParsing_invalidToken", testParsing_invalidToken),
        ("testParsing_simpleString_chunked", testParsing_simpleString_chunked),
        ("testParsing_simpleString_handlesRecursion", testParsing_simpleString_handlesRecursion),
        ("testParsing_simpleString_missingNewline", testParsing_simpleString_missingNewline),
        ("testParsing_simpleString_withContent", testParsing_simpleString_withContent),
        ("testParsing_simpleString_withNoContent", testParsing_simpleString_withNoContent),
        ("testParsing_simpleString", testParsing_simpleString),
        ("testSimpleStringWithoutRemovingToken", testSimpleStringWithoutRemovingToken),
        ("testWriting_arrays", testWriting_arrays),
        ("testWriting_bulkStrings", testWriting_bulkStrings),
        ("testWriting_errors", testWriting_errors),
        ("testWriting_foundationData", testWriting_foundationData),
        ("testWriting_integers", testWriting_integers),
        ("testWriting_null", testWriting_null),
        ("testWriting_simpleStrings", testWriting_simpleStrings),
    ]
}

extension RESPValueTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__RESPValueTests = [
        ("test_equatable", test_equatable),
    ]
}

extension RedisByteDecoderTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__RedisByteDecoderTests = [
        ("test_badMessage_throws", test_badMessage_throws),
        ("test_complete_continues", test_complete_continues),
        ("test_complete_movesReaderIndex", test_complete_movesReaderIndex),
        ("test_partial_needsMoreData", test_partial_needsMoreData),
        ("test_validatesBasicAssumptions_withNonStringRepresentables", test_validatesBasicAssumptions_withNonStringRepresentables),
        ("test_validatesBasicAssumptions", test_validatesBasicAssumptions),
        ("testAll", testAll),
        ("testArrays", testArrays),
        ("testBulkStrings", testBulkStrings),
        ("testErrors", testErrors),
        ("testIntegers", testIntegers),
        ("testSimpleStrings", testSimpleStrings),
    ]
}

extension RedisMessageEncoderTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__RedisMessageEncoderTests = [
        ("testArrays", testArrays),
        ("testBulkStrings", testBulkStrings),
        ("testError", testError),
        ("testIntegers", testIntegers),
        ("testNull", testNull),
        ("testSimpleStrings", testSimpleStrings),
    ]
}

public func __allTests() -> [XCTestCaseEntry] {
    return [
        testCase(RESPTranslatorTests.__allTests__RESPTranslatorTests),
        testCase(RESPValueTests.__allTests__RESPValueTests),
        testCase(RedisByteDecoderTests.__allTests__RedisByteDecoderTests),
        testCase(RedisMessageEncoderTests.__allTests__RedisMessageEncoderTests),
    ]
}
#endif
