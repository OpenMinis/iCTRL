import Foundation
import CoreGraphics

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    guard condition() else { fatalError(message) }
}
let size = CGSize(width: 390, height: 844)
func point(_ x: Double, _ y: Double) -> JSONValue { .object(["x": .double(x), "y": .double(y)]) }
let valid: [JSONValue] = [point(50, 200), point(150, 200), point(150, 300)]
func rejected(_ params: [String: JSONValue]) {
    let (path, error) = ContinuousDragPath.parse(params, screenSize: size)
    check(path == nil && error?.code == -32602, "Invalid path accepted: \(params)")
}
let (parsed, error) = ContinuousDragPath.parse(["points": .array(valid)], screenSize: size)
check(error == nil && parsed != nil, "Valid path rejected")
let path = parsed!
check(path.duration == 1, "Unexpected default duration")
check(path.points == [CGPoint(x: 50, y: 200), CGPoint(x: 150, y: 200), CGPoint(x: 150, y: 300)], "Waypoints changed")
check(path.samples.last!.point == path.points.last!, "Last endpoint missing")
check(path.samples.last!.offset == path.duration, "Total duration changed")
check(path.samples.contains(where: { $0.point == path.points[1] && $0.offset == 0.5 }), "Corner cut or retimed")
var previous = 0.0
for sample in path.samples {
    check(sample.offset > previous, "Offsets not strictly increasing")
    check(sample.offset <= path.duration, "Offset past duration")
    previous = sample.offset
}
for raw in [JSONValue.null, .object([:]), .string("bad"), .array([]), .array([point(1, 1)]), .array(Array(repeating: point(1, 1), count: 65))] {
    rejected(["points": raw])
}
for raw in [JSONValue.string("1"), .bool(true), .null, .double(.nan), .double(.infinity), .double(-1), .double(0), .double(0.099), .double(10.001)] {
    rejected(["points": .array(valid), "duration": raw])
}
for invalid in [point(-1, 1), point(391, 1), point(1, -1), point(1, 845), point(.nan, 1), point(1, .infinity), .null, .object(["x": .int(1)]), .object(["x": .bool(true), "y": .int(1)]), .object(["x": .string("1"), "y": .int(1)])] {
    rejected(["points": .array([point(1, 1), invalid])])
}
for key in ["from_x", "from_y", "to_x", "to_y", "from_ref", "to_ref"] {
    // Even malformed/null endpoint fields must not silently coexist with points.
    rejected(["points": .array(valid), key: .null])
    rejected(["points": .array(valid), key: .string("bad")])
}
for duration in [0.1, 10.0] {
    let (path, error) = ContinuousDragPath.parse(["points": .array(Array(repeating: point(390, 844), count: 64)), "duration": .double(duration)], screenSize: size)
    check(error == nil && path != nil, "Valid boundary rejected")
    let samples = path!.samples
    check(samples.count < 700, "Unbounded synthesis cost")
    check(samples.allSatisfy { $0.point == CGPoint(x: 390, y: 844) }, "Hold moved")
    check(abs(samples.last!.offset - duration) < 1e-12, "Boundary duration drift")
    check(zip(samples, samples.dropFirst()).allSatisfy { $0.offset < $1.offset }, "Repeated waypoint offsets invalid")
}
check(ContinuousDragPath.startPoint(["points": .array(valid)]) == CGPoint(x: 50, y: 200), "Challenge check misses path start")
check(ContinuousDragPath.startPoint(["points": .array([point(.nan, 1)])]) == nil, "Nonfinite challenge start accepted")
check(ContinuousDragPath.rpcBudget(["points": .array(valid), "duration": .double(10)], defaultBudget: 6) == 15, "Long path would time out")
check(ContinuousDragPath.rpcBudget(nil, defaultBudget: 6) == 6, "Legacy watchdog changed")
check(ContinuousDragPath.rpcBudget(["duration": .double(10)], defaultBudget: 6) == 6, "Endpoint watchdog changed")
check(ContinuousDragPath.rpcBudget(["points": .array(valid), "duration": .double(.infinity)], defaultBudget: 6) == 6, "Unbounded watchdog")
let legacy = ActionCommand(method: "drag", params: ["from_x": .int(1), "from_y": .int(2), "to_x": .int(3), "to_y": .int(4)])
check(legacy.dragPathParams == nil && legacy.fromX == 1 && legacy.toY == 4, "Legacy decoding changed")
let unrelated = ActionCommand(method: "tap", params: ["points": .array(valid)])
check(unrelated.dragPathParams == nil, "Path arguments changed another method")
let malformed = ActionCommand(method: "drag", params: ["points": .null])
check(malformed.dragPathParams != nil, "Explicit null path silently falls back to endpoints")
let request = try JSONDecoder().decode(JSONRPCRequest.self, from: Data(#"{"jsonrpc":"2.0","method":"drag","params":{"points":[{"x":50,"y":200},{"x":150,"y":200},{"x":150,"y":300}],"duration":1.2},"id":1}"#.utf8))
let command = ActionCommand(method: request.method, params: request.params)
let (decoded, decodeError) = ContinuousDragPath.parse(command.dragPathParams!, screenSize: size)
check(decodeError == nil && decoded?.duration == 1.2 && decoded?.points.count == 3, "RPC path decoding failed")
print("ContinuousDragPath: \(checks) checks passed")
