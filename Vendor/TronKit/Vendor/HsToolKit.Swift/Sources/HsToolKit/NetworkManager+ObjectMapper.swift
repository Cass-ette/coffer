import Alamofire
import Foundation
import ObjectMapper

public extension NetworkManager {
    func fetch<T: ImmutableMappable>(
        url: URLConvertible, method: HTTPMethod = .get, parameters: Parameters = [:], encoding: ParameterEncoding = URLEncoding.default,
        headers: HTTPHeaders? = nil, interceptor: RequestInterceptor? = nil, responseCacherBehavior: ResponseCacher.Behavior? = nil,
        context: MapContext? = nil
    ) async throws -> T {
        let json = try await fetchJson(
            url: url, method: method, parameters: parameters, encoding: encoding, headers: headers, interceptor: interceptor,
            responseCacherBehavior: responseCacherBehavior
        )

        return try T(JSONObject: json, context: context)
    }

    func fetch<T: ImmutableMappable>(
        url: URLConvertible, method: HTTPMethod = .get, parameters: Parameters = [:], encoding: ParameterEncoding = URLEncoding.default,
        headers: HTTPHeaders? = nil, interceptor: RequestInterceptor? = nil, responseCacherBehavior: ResponseCacher.Behavior? = nil,
        context: MapContext? = nil
    ) async throws -> [T] {
        let json = try await fetchJson(
            url: url, method: method, parameters: parameters, encoding: encoding, headers: headers, interceptor: interceptor,
            responseCacherBehavior: responseCacherBehavior
        )

        return try Mapper<T>(context: context).mapArray(JSONObject: json)
    }

    func fetch<T: ImmutableMappable>(
        url: URLConvertible, method: HTTPMethod = .get, parameters: Parameters = [:], encoding: ParameterEncoding = URLEncoding.default,
        headers: HTTPHeaders? = nil, interceptor: RequestInterceptor? = nil, responseCacherBehavior: ResponseCacher.Behavior? = nil,
        context: MapContext? = nil
    ) async throws -> [String: T] {
        let json = try await fetchJson(
            url: url, method: method, parameters: parameters, encoding: encoding, headers: headers, interceptor: interceptor,
            responseCacherBehavior: responseCacherBehavior
        )

        return try Mapper<T>(context: context).mapDictionary(JSONObject: json)
    }
}
