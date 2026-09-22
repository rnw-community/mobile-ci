# Affected-tests fixtures

`map.json` is a well-formed path-to-test map in the shape
`actions/xcodebuild-affected-tests` documents; the other files are the
malformed shapes its tests prove it refuses (an entry with no tests would skip
a change silently, an identifier that starts with `-` would be read by
`xcodebuild` as a flag, and a map that is not an array is not a map).
