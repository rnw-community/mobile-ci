/// The smallest unit of behaviour the `swift-test` action needs in order to
/// prove it compiled, ran, and reported a real test count.
public enum FixtureCore {
    public static func sum(_ values: [Int]) -> Int {
        values.reduce(0, +)
    }
}
