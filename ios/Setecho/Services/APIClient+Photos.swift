import Foundation

/// /photos/segment response: box and crop in the uploaded image's own pixels.
struct SegmentResponse: Codable, Equatable {
    var width: Int
    var height: Int
    var box: [Int]
    var crop: [Int]
    var bodyFraction: Double
    var clamped: Bool
    var maskPng: String
    var maskWidth: Int
    var maskHeight: Int

    var boxRect: CGRect { CGRect(x: box[0], y: box[1], width: box[2], height: box[3]) }
    var cropRect: CGRect { CGRect(x: crop[0], y: crop[1], width: crop[2], height: crop[3]) }
    var maskData: Data? { Data(base64Encoded: maskPng) }
}

extension APIClient {
    /// One pose still -> person box, the aligned crop and the mask. `referenceFraction` is the
    /// reference week's body fraction for the same pose, nil for the first set ever.
    func segment(jpeg: Data, referenceFraction: Double?) async throws -> SegmentResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("/photos/segment"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        var parts: [Multipart.Part] = [.file(name: "image", filename: "pose.jpg", mime: "image/jpeg", data: jpeg)]
        if let referenceFraction {
            parts.append(.field(name: "referenceFraction", value: String(referenceFraction)))
        }
        let body = Multipart(parts: parts)
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError(status: 0, message: "No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorBody: Decodable { let error: String }
            let message = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? "HTTP \(http.statusCode)"
            throw APIError(status: http.statusCode, message: message)
        }
        return try JSONCoding.decoder.decode(SegmentResponse.self, from: data)
    }
}
