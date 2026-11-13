import ballerina/test;

@test:Config {}
function testQuantity() {
    // Issue: checkpanic instead of check, reported only when the tests are scanned.
    int quantity = checkpanic int:fromString("3");
    test:assertEquals(quantity, 3);
}
