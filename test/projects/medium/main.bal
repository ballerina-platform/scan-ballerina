import ballerina/io;

type Credentials record {|
    string username;
    string password;
|};

final string defaultValue = "value";

public isolated function main() {
    // Issue: a secret taken from a variable that is not configurable.
    Credentials credentials = {username: "admin", password: defaultValue};
    io:println(credentials.username);
}
