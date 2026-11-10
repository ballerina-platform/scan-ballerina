// No imports, so Dependencies.toml locks no library version that Ballerina 2201.12.0 may lack.
public function main() {
    // Issue: checkpanic instead of check.
    int quantity = checkpanic int:fromString("3");
    _ = quantity;
}
