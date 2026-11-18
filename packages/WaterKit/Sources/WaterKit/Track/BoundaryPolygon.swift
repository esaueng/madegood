import Foundation

/// Pack vertices use integer microdegrees so segment intersection checks are exact.
struct BoundaryVertex: Decodable, Hashable, Sendable {
    let x: Int
    let y: Int

    init(from decoder: any Decoder) throws {
        var pair = try decoder.unkeyedContainer()
        x = try pair.decode(Int.self)
        y = try pair.decode(Int.self)
        guard pair.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: pair, debugDescription: "Expected longitude and latitude")
        }
    }

    func turn(_ second: Self, _ third: Self) -> Int {
        (second.x - x) * (third.y - y) - (second.y - y) * (third.x - x)
    }
}

struct BoundaryPolygon: Decodable, Sendable {
    let outer: [BoundaryVertex]
    let holes: [[BoundaryVertex]]

    /// Validate only after all coordinates have been checked against the pack bounds.
    func isValid() -> Bool {
        let outline = Ring(outer)
        guard outline.isSimple else { return false }
        var checkedHoles: [Ring] = []
        for hole in holes {
            let ring = Ring(hole)
            guard ring.isSimple, outline.contains(hole[0]), !outline.intersects(ring) else { return false }
            for checked in checkedHoles {
                guard !checked.intersects(ring), !checked.contains(hole[0]), !ring.contains(checked.vertices[0])
                else { return false }
            }
            checkedHoles.append(ring)
        }
        return true
    }

    func measure(at point: BoundaryPoint, longitudeScale: Double) -> (inside: Bool, distance: Double) {
        let outline = Ring(outer)
        var inside = outline.contains(point)
        var distance = outline.distance(to: point, longitudeScale: longitudeScale)
        for hole in holes {
            let ring = Ring(hole)
            if ring.contains(point) { inside = false }
            distance = min(distance, ring.distance(to: point, longitudeScale: longitudeScale))
        }
        return (inside, distance)
    }

    private struct Ring {
        let vertices: [BoundaryVertex]

        init(_ vertices: [BoundaryVertex]) {
            self.vertices = vertices
        }

        func next(_ index: Int) -> Int {
            (index + 1) % vertices.count
        }

        func contains(_ vertex: BoundaryVertex) -> Bool {
            contains(BoundaryPoint(x: Double(vertex.x), y: Double(vertex.y)))
        }

        func contains(_ point: BoundaryPoint) -> Bool {
            var inside = false
            for index in vertices.indices {
                let a = vertices[index]
                let b = vertices[next(index)]
                let dy = point.y - Double(a.y)
                if (Double(a.y) > point.y) != (Double(b.y) > point.y),
                    point.x - Double(a.x) < dy * Double(b.x - a.x) / Double(b.y - a.y)
                {
                    inside.toggle()
                }
            }
            return inside
        }

        func distance(to point: BoundaryPoint, longitudeScale: Double) -> Double {
            var squaredDistance = Double.infinity
            for index in vertices.indices {
                let a = vertices[index]
                let b = vertices[next(index)]
                let dx = Double(b.x - a.x) * longitudeScale
                let dy = Double(b.y - a.y) * BoundaryPoint.latitudeScale
                let x = (point.x - Double(a.x)) * longitudeScale
                let y = (point.y - Double(a.y)) * BoundaryPoint.latitudeScale
                let projection = max(0, min(1, (dx * x + dy * y) / (dx * dx + dy * dy)))
                let rx = x - projection * dx
                let ry = y - projection * dy
                squaredDistance = min(squaredDistance, rx * rx + ry * ry)
            }
            return squaredDistance.squareRoot()
        }

        var isSimple: Bool {
            guard vertices.count >= 3, Set(vertices).count == vertices.count else { return false }
            for index in vertices.indices {
                let following = next(index)
                // V1 requires removal of redundant collinear vertices and disallows backtracking.
                guard vertices[index].turn(vertices[following], vertices[next(following)]) != 0 else { return false }
                let edge = Segment(start: vertices[index], end: vertices[following])
                for other in vertices.indices.dropFirst(index + 2) {
                    let otherEnd = next(other)
                    if otherEnd == index { continue }
                    if edge.intersects(Segment(start: vertices[other], end: vertices[otherEnd])) { return false }
                }
            }
            return true
        }

        func intersects(_ other: Self) -> Bool {
            for index in vertices.indices {
                let edge = Segment(start: vertices[index], end: vertices[next(index)])
                for otherIndex in other.vertices.indices {
                    let otherEdge = Segment(
                        start: other.vertices[otherIndex], end: other.vertices[other.next(otherIndex)])
                    if edge.intersects(otherEdge) { return true }
                }
            }
            return false
        }
    }

    private struct Segment {
        let start: BoundaryVertex
        let end: BoundaryVertex

        func intersects(_ other: Self) -> Bool {
            guard
                max(min(start.x, end.x), min(other.start.x, other.end.x))
                    <= min(max(start.x, end.x), max(other.start.x, other.end.x)),
                max(min(start.y, end.y), min(other.start.y, other.end.y))
                    <= min(max(start.y, end.y), max(other.start.y, other.end.y))
            else { return false }

            let a = start.turn(end, other.start).signum()
            let b = start.turn(end, other.end).signum()
            let c = other.start.turn(other.end, start).signum()
            let d = other.start.turn(other.end, end).signum()
            return a * b <= 0 && c * d <= 0
        }
    }
}

struct BoundaryPoint {
    // 110 km per degree is below the minimum WGS84 meridional radius scale and
    // the minimum prime vertical radius scale before the longitude cosine factor.
    static let latitudeScale = 0.11
    let x: Double
    let y: Double
}
