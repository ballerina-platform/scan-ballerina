import ballerina/io;

public function main() {
    // Issue: checkpanic instead of check.
    int amount = checkpanic int:fromString("10");
    io:println(amount);
}
