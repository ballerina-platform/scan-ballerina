import ballerina/io;

public function main() {
    // Issue: checkpanic instead of check.
    int quantity = checkpanic int:fromString("3");
    io:println(quantity);
}
