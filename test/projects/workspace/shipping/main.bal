import ballerina/io;

public function main() {
    // Issue: checkpanic instead of check.
    int weight = checkpanic int:fromString("2");
    // Issue: variable assigned to itself, excluded by the workspace's Scan.toml.
    weight = weight;
    io:println(weight);
}
