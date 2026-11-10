import ballerina/io;

type Credentials record {|
    string username;
    string password;
|};

public isolated function main() {
    // Issue: a secret that is not configurable.
    Credentials credentials = {username: "admin", password: "s3cr3t-Passw0rd"};
    io:println(credentials.username);
}
