import Foundation

/// A single finger following waypoints; independent of XCTest so validation and
/// timing can be tested without injecting touches into a device.
struct ContinuousDragPath {
    struct Sample {
        let point: CGPoint
        let offset: TimeInterval
    }

    let points: [CGPoint]
    let duration: TimeInterval

    static func parse(_ params: [String: JSONValue], screenSize: CGSize)
        -> (ContinuousDragPath?, JSONRPCError?) {
        func invalid(_ message: String) -> (ContinuousDragPath?, JSONRPCError?) {
            (nil, JSONRPCError(code: -32602, message: message, data: nil))
        }
        guard case .array(let values)? = params["points"], (2...64).contains(values.count) else {
            return invalid("drag points requires an array of 2...64 {x,y} objects")
        }
        let endpoints = ["from_x", "from_y", "to_x", "to_y", "from_ref", "to_ref"]
        guard !endpoints.contains(where: { params[$0] != nil }) else {
            return invalid("drag points cannot be combined with endpoint coordinates or refs")
        }
        let duration: Double
        if let raw = params["duration"] {
            guard let value = raw.doubleValue else { return invalid("drag points duration must be a number") }
            duration = value
        } else {
            duration = 1.0
        }
        guard duration.isFinite, (0.1...10.0).contains(duration) else {
            return invalid("drag points duration must be finite and between 0.1 and 10 seconds")
        }
        var points: [CGPoint] = []
        for value in values {
            guard let item = value.objectValue, let x = item["x"]?.doubleValue,
                  let y = item["y"]?.doubleValue, x.isFinite, y.isFinite else {
                return invalid("Each drag point requires finite numeric x and y")
            }
            guard x >= 0, y >= 0, x <= screenSize.width, y <= screenSize.height else {
                return invalid("drag point (\(x),\(y)) is outside the screen in POINTS")
            }
            points.append(CGPoint(x: x, y: y))
        }
        return (ContinuousDragPath(points: points, duration: duration), nil)
    }

    /// Match the existing drag's start-point challenge check, including for
    /// malformed requests (which parse() will reject before touch injection).
    static func startPoint(_ params: [String: JSONValue]?) -> CGPoint? {
        guard case .array(let values)? = params?["points"],
              let first = values.first?.objectValue,
              let x = first["x"]?.doubleValue, let y = first["y"]?.doubleValue,
              x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// A legitimate long path must not time out while its touch is still down.
    /// Reserve up to 3s for settle plus 2s for synthesis/dispatch overhead.
    static func rpcBudget(_ params: [String: JSONValue]?, defaultBudget: TimeInterval) -> TimeInterval {
        guard case .array? = params?["points"] else { return defaultBudget }
        let duration = params?["duration"]?.doubleValue ?? 1.0
        guard duration.isFinite, (0.1...10.0).contains(duration) else { return defaultBudget }
        return max(defaultBudget, duration + 5)
    }

    /// Equal time per segment, including zero-length segments (a hold). Samples
    /// retain each exact waypoint and strictly increasing offsets across corners.
    var samples: [Sample] {
        let segmentDuration = duration / Double(points.count - 1)
        let count = max(1, Int(ceil(segmentDuration * 60)))
        var result: [Sample] = []
        for index in 1..<points.count {
            let start = points[index - 1], end = points[index]
            for sample in 1...count {
                let fraction = Double(sample) / Double(count)
                let point = sample == count ? end : CGPoint(
                    x: start.x + (end.x - start.x) * fraction,
                    y: start.y + (end.y - start.y) * fraction)
                result.append(Sample(point: point,
                                     offset: (Double(index - 1) + fraction) * segmentDuration))
            }
        }
        return result
    }
}
