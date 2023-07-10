//===----------------------------------------------------------------------===//
//
// This source file is part of the RediStack open source project
//
// Copyright (c) 2020-2023 RediStack project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of RediStack project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Atomics
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix
import NIOSSL
import Logging
import struct Foundation.URL
import protocol Foundation.LocalizedError

extension RedisConnection {
    /// A configuration object for creating a single connection to Redis.
    public struct Configuration: Sendable {

        /// The possible modes of operation for TLS encapsulation of a connection.
        public struct TLS: Sendable {
            enum Base {
                case disable
                case enable(NIOSSLContext)
            }
            let base: Base
            private init(base: Base) { self.base = base }

            // MARK: Initializers

            /// Do not try to create a TLS connection to the server.
            public static var disable: Self = .init(base: .disable)

            /// Try to create a TLS connection to the server. If the server supports TLS, create a TLS connection.
            /// If the server does not support TLS, fail the connection creation.
            public static func enable(_ sslContext: NIOSSLContext) -> Self {
                self.init(base: .enable(sslContext))
            }
        }

        private static let _defaultPortAtomic = ManagedAtomic(6379)

        /// The default port that Redis uses.
        ///
        /// See [https://redis.io/topics/quickstart](https://redis.io/topics/quickstart)
        public static var defaultPort: Int {
            get {
                self._defaultPortAtomic.load(ordering: .acquiring)
            }
            @available(*, deprecated, message: "Setting the default Redis port will be removed in the next major release")
            set {
                self._defaultPortAtomic.store(newValue, ordering: .releasing)
            }
        }

        internal static let defaultLogger = Logger.redisBaseConnectionLogger

        /// The hostname of the connection address. If the address is a Unix socket, then it will be `nil`.
        public var hostname: String? {
            self.endpointInfo.hostname
        }

        /// The port of the connection address. If the address is a Unix socket, then it will be `nil`.
        public var port: Int? {
            self.endpointInfo.port
        }

        /// The user name used to authenticate connections with.
        /// - Warning: This property should only be provided if you are running against Redis 6 or higher.
        public var username: String?
        /// The password used to authenticate the connection.
        public var password: String?
        /// The initial database index that the connection should use.
        public var initialDatabase: Int?
        /// The logger prototype that will be used by the connection by default when generating logs.
        public var defaultLogger: Logger

        /// The TLS mode to use for the connection. Valid for all configurations.
        ///
        /// See ``TLS-swift.struct``.
        public var tls: TLS

        internal let endpointInfo: EndpointInfo

        public init(
            host: String = "localhost",
            port: Int = 6379,
            customBootstrap bootstrap: NIOClientTCPBootstrapProtocol? = nil
        ) {
            self.init(endpoint: .connectTCP(host: host, port: port, bootstrap: bootstrap))
        }

        public init(address: SocketAddress) {
            self.init(endpoint: .resolved(address))
        }

        public init(establishedChannel channel: Channel) {
            self.init(endpoint: .configureChannel(channel))
        }

        private init(endpoint: EndpointInfo) {
            self.endpointInfo = endpoint
            self.tls = .disable
            self.password = nil
            self.username = nil
            self.initialDatabase = nil
            self.defaultLogger = Configuration.defaultLogger
        }

        // MARK: - Convenience initializers

        /// Creates a new connection configuration with the provided details.
        /// - Parameters:
        ///     - `address`: The socket address information to use for creating the Redis connection.
        ///     - `username`: The optional username to authenticate the connection with. The default is `nil`.
        ///     - `password`: The optional password to authenticate the connection with. The default is `nil`.
        ///     - `initialDatabase`: The optional database index to initially connect to. The default is `nil`.
        ///       Redis by default opens connections against index `0`, so only set this value if the desired default is not `0`.
        ///     - `defaultLogger`: The optional prototype logger to use as the default logger instance when generating logs from the connection.
        ///     If one is not provided, one will be generated. See `RedisLogging.baseConnectionLogger`.
        /// - Throws: `RedisConnection.Configuration.ValidationError` if invalid arguments are provided.
        public init(
            address: SocketAddress,
            username: String? = nil,
            password: String? = nil,
            initialDatabase: Int? = nil,
            defaultLogger: Logger? = nil
        ) throws {
            if initialDatabase != nil && initialDatabase! < 0 {
                throw ValidationError.outOfBoundsDatabaseID
            }

            self.init(endpoint: .resolved(address))
            self.username = username
            self.password = password
            self.initialDatabase = initialDatabase
            self.defaultLogger = defaultLogger ?? Configuration.defaultLogger
        }

        /// Creates a new connection configuration with the provided details.
        /// - Parameters:
        ///     - `address`: The socket address information to use for creating the Redis connection.
        ///     - `password`: The optional password to authenticate the connection with. The default is `nil`.
        ///     - `initialDatabase`: The optional database index to initially connect to. The default is `nil`.
        ///       Redis by default opens connections against index `0`, so only set this value if the desired default is not `0`.
        ///     - `defaultLogger`: The optional prototype logger to use as the default logger instance when generating logs from the connection.
        ///     If one is not provided, one will be generated. See `RedisLogging.baseConnectionLogger`.
        /// - Throws: `RedisConnection.Configuration.ValidationError` if invalid arguments are provided.
        public init(
            address: SocketAddress,
            password: String? = nil,
            initialDatabase: Int? = nil,
            defaultLogger: Logger? = nil
        ) throws {
            try self.init(
                address: address,
                username: nil,
                password: password,
                initialDatabase: initialDatabase,
                defaultLogger: defaultLogger
            )
        }

        /// Creates a new connection configuration with exact details.
        /// - Parameters:
        ///     - hostname: The remote hostname to connect to.
        ///     - port: The port that the Redis instance connects with. The default is `RedisConnection.Configuration.defaultPort`.
        ///     - password: The optional password to authenticate the connection with. The default is `nil`.
        ///     - initialDatabase: The optional database index to initially connect to. The default is `nil`.
        ///     Redis by default opens connections against index `0`, so only set this value if the desired default is not `0`.
        ///     - defaultLogger: The optional prototype logger to use as the default logger instance when generating logs from the connection.
        ///     If one is not provided, one will be generated. See `RedisLogging.baseConnectionLogger`.
        /// - Throws:
        ///     - `NIO.SocketAddressError` if hostname resolution fails.
        ///     - `RedisConnection.Configuration.ValidationError` if invalid arguments are provided.
        public init(
            hostname: String,
            port: Int = Self.defaultPort,
            password: String? = nil,
            initialDatabase: Int? = nil,
            defaultLogger: Logger? = nil
        ) throws {
            try self.init(
                address: try .makeAddressResolvingHost(hostname, port: port),
                password: password,
                initialDatabase: initialDatabase,
                defaultLogger: defaultLogger
            )
        }

        /// Creates a new connection configuration from the provided RFC 1808 URL formatted string.
        ///
        /// This is a convenience initializer over creating a `Foundation.URL` directly and passing it to the overloaded initializer.
        ///
        /// The string is expected to match the [RFC 1808](https://tools.ietf.org/html/rfc1808) format.
        ///
        /// An example string:
        ///
        ///     redis://:password@localhost:6379/3
        ///
        /// For more details, see the `Configuration.init(url:)` overload that accepts a `Foundation.URL`.
        /// - Parameters:
        ///     - string: The URL formatted string.
        ///     - defaultLogger: The optional prototype logger to use as the default logger instance when generating logs from the connection.
        ///     If one is not provided, one will be generated. See `RedisLogging.baseConnectionLogger`.
        /// - Throws:
        ///     - `RedisConnection.Configuration.ValidationError` if required URL components are invalid or missing.
        ///     - `NIO.SocketAddressError` if hostname resolution fails.
        public init(url string: String, defaultLogger: Logger? = nil) throws {
            guard let url = URL(string: string) else { throw ValidationError.invalidURLString }
            try self.init(url: url, defaultLogger: defaultLogger)
        }

        /// Creates a new connection configuration from the provided URL object.
        ///
        /// The `scheme` and `host` are the only properties that need to be established.
        /// - Invariant: The `port` property is optional, with the `RedisConnection.Configuration.defaultPort` being used by default.
        /// - Invariant: `password` is only required if the Redis instance specifies a password is required. This will not be detected until trying to establish a connection
        /// with this configuration.
        /// - Invariant: To set the default selected database index, provide the index as the `lastPathComponent` of the `Foundation.URL`.
        /// - Requires: The URL **must** use the `redis://` scheme.
        /// - Parameters:
        ///     - url: The URL to use to resolve and authenticate the remote connection.
        ///     - defaultLogger: The optional prototype logger to use as the default logger instance when generating logs from the connection.
        ///     If one is not provided, one will be generated. See `RedisLogging.baseConnectionLogger`.
        /// - Throws:
        ///     - `RedisConnection.Configuration.ValidationError` if required URL components are invalid or missing.
        ///     - `NIO.SocketAddressError` if hostname resolution fails.
        public init(url: URL, defaultLogger: Logger? = nil) throws {
            try Self.validateRedisURL(url)

            guard let host = url.host, !host.isEmpty else { throw ValidationError.missingURLHost }

            let databaseID = Int(url.lastPathComponent)

            try self.init(
                address: try .makeAddressResolvingHost(host, port: url.port ?? Self.defaultPort),
                password: url.password,
                initialDatabase: databaseID,
                defaultLogger: defaultLogger
            )
        }

        // MARK: - Implementation details

        enum EndpointInfo {
            case configureChannel(Channel)
            case connectTCP(host: String, port: Int, bootstrap: NIOClientTCPBootstrapProtocol?)
            case resolved(SocketAddress)

            // TODO: Enable unix domain socket support
            // case bindUnixDomainSocket(path: String)

            var hostname: String? {
                switch self {
                case .configureChannel(let channel):
                    return channel.remoteAddress?.hostname

                case .connectTCP(let host, _, _):
                    return host

                case .resolved(let socketAddress):
                    return socketAddress.hostname
                }
            }

            var port: Int? {
                switch self {
                case .configureChannel(let channel):
                    return channel.remoteAddress?.port

                case .connectTCP(_, let port, _):
                    return port

                case .resolved(let socketAddress):
                    return socketAddress.port
                }
            }
        }

        init(
            endpointInfo: EndpointInfo,
            tls: TLS,
            username: String,
            password: String?,
            database: Int?,
            logger: Logger
        ) {
            self.endpointInfo = endpointInfo
            self.tls = tls
            self.username = username
            self.password = password
            self.initialDatabase = database
            self.defaultLogger = logger
        }

        private static func validateRedisURL(_ url: URL) throws {
            guard
                let scheme = url.scheme,
                !scheme.isEmpty
            else { throw ValidationError.missingURLScheme }

            guard scheme == "redis" else { throw ValidationError.invalidURLScheme }
        }
    }
}

extension RedisConnection.Configuration {
    public struct ValidationError: LocalizedError, Equatable {
        public static let invalidURLString = ValidationError(.invalidURLString)
        public static let missingURLScheme = ValidationError(.missingURLScheme)
        public static let invalidURLScheme = ValidationError(.invalidURLScheme)
        public static let missingURLHost = ValidationError(.missingURLHost)
        public static let outOfBoundsDatabaseID = ValidationError(.outOfBoundsDatabaseID)

        var localizedDescription: String { self.kind.localizedDescription }

        private let kind: Kind

        private init(_ kind: Kind) { self.kind = kind }

        public static func ==(lhs: ValidationError, rhs: ValidationError) -> Bool {
            return lhs.kind == rhs.kind
        }

        private enum Kind: LocalizedError {
            case invalidURLString
            case missingURLScheme
            case invalidURLScheme
            case missingURLHost
            case outOfBoundsDatabaseID

            var localizedDescription: String {
                let message: String = {
                    switch self {
                    case .invalidURLString: return "invalid URL string"
                    case .missingURLScheme: return "URL scheme is missing"
                    case .invalidURLScheme: return "invalid URL scheme, expected 'redis'"
                    case .missingURLHost: return "missing remote hostname"
                    case .outOfBoundsDatabaseID: return "database index out of bounds"
                    }
                }()
                return "(RediStack) \(RedisConnection.Configuration.self) validation failed: \(message)"
            }
        }
    }
}

extension SocketAddress {
    fileprivate var hostname: String? {
        switch self {
        case let .v4(addr): return addr.host
        case let .v6(addr): return addr.host
        case .unixDomainSocket: return nil
        }
    }
}
