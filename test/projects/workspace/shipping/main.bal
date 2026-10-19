import ballerina/io;

public function main() {
    // Issue: checkpanic instead of check.
    int weight = checkpanic int:fromString("2");
    io:println(weight);
}
