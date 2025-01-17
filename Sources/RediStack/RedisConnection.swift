//===----------------------------------------------------------------------===//
//
// This source file is part of the RediStack open source project
//
// Copyright (c) 2019-2021 RediStack project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of RediStack project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import struct Foundation.UUID
import struct Dispatch.DispatchTime
import Atomics
import Logging
import Metrics
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix

extension RedisConnection {

    /// Creates a new connection with provided configuration and sychronization objects.
    ///
    /// If you would like to specialize the `NIO.ClientBootstrap` that the connection communicates on, override the default by passing it in as `configuredTCPClient`.
    ///
    ///     let eventLoopGroup: EventLoopGroup = ...
    ///     var customTCPClient = ClientBootstrap.makeRedisTCPClient(group: eventLoopGroup)
    ///     customTCPClient.channelInitializer { channel in
    ///         // channel customizations
    ///     }
    ///     let connection = RedisConnection.make(
    ///         configuration: ...,
    ///         boundEventLoop: eventLoopGroup.next(),
    ///         configuredTCPClient: customTCPClient
    ///     ).wait()
    ///
    /// It is recommended that you be familiar with `ClientBootstrap.makeRedisTCPClient(group:)` and `NIO.ClientBootstrap` in general before doing so.
    ///
    /// Note: Use of `wait()` in the example is for simplicity. Never call `wait()` on an event loop.
    ///
    /// - Important: Call `close()` on the connection before letting the instance deinit to properly cleanup resources.
    /// - Invariant: If a `password` is provided in the configuration, the connection will send an "AUTH" command to Redis as soon as it has been opened.
    /// - Invariant: If a `database` index is provided in the configuration, the connection will send a "SELECT" command to Redis after it has been authenticated.
    /// - Parameters:
    ///     - config: The configuration to use for creating the connection.
    ///     - eventLoop: The `NIO.EventLoop` that the connection will be bound to.
    ///     - client: If you have chosen to configure a `NIO.ClientBootstrap` yourself, this will be used instead of the `.makeRedisTCPClient` factory instance.
    /// - Returns: A `NIO.EventLoopFuture` that resolves with the new connection after it has been opened, configured, and authenticated per the `configuration` object.
    public static func make(
        configuration config: Configuration,
        boundEventLoop eventLoop: EventLoop,
        configuredTCPClient client: ClientBootstrap? = nil
    ) -> EventLoopFuture<RedisConnection> {
        let client = client ?? .makeRedisTCPClient(group: eventLoop)

        var future = client
            .connect(to: config.address)
            .map { return RedisConnection(configuredRESPChannel: $0, context: config.defaultLogger) }

        // if a password is specified, use it to authenticate before further operations happen
        if let password = config.password {
            future = future.flatMap { connection in
                return connection.authorize(with: password).map { connection }
            }
        }

        // if a database index is specified, use it to switch the selected database before further operations happen
        if let database = config.initialDatabase {
            future = future.flatMap { connection in
                return connection.select(database: database).map { connection }
            }
        }

        return future
    }
}

/// A concrete `RedisClient` implementation that represents an individual connection to a Redis instance.
///
/// For basic setups, you will just need a `NIO.EventLoop` and perhaps a `password`.
///
///     let eventLoop: EventLoop = ...
///     let connection = RedisConnection.make(
///         configuration: .init(hostname: "my.redis.url", password: "some_password"),
///         boundEventLoop: eventLoop
///     ).wait()
///
///     let result = try connection.set("my_key", to: "some value")
///         .flatMap { return connection.get("my_key") }
///         .wait()
///
///     print(result) // Optional("some value")
///
/// Note: `wait()` is used in the example for simplicity. Never call `wait()` on an event loop.
public final class RedisConnection: RedisClient, RedisClientWithUserContext {
    /// A unique identifer to represent this connection.
    public let id = UUID()
    public var eventLoop: EventLoop { return self.channel.eventLoop }
    /// Is the connection to Redis still open?
    public var isConnected: Bool {
        // `Channel.isActive` is set to false before the `closeFuture` resolves in cases where the channel might be
        // closed, or closing, before our state has been updated
        return self.channel.isActive && self.state.isConnected
    }
    /// Is the connection currently subscribed for PubSub?
    ///
    /// Only a narrow list of commands are allowed when in "PubSub mode".
    ///
    /// See [PUBSUB](https://redis.io/topics/pubsub).
    public var isSubscribed: Bool { self.state.isSubscribed }
    /// Controls the behavior of when sending commands over this connection. The default is `true.
    ///
    /// When set to `false`, the commands will be placed into a buffer, and the host machine will determine when to drain the buffer.
    /// When set to `true`, the buffer will be drained as soon as commands are added.
    /// - Important: Even when set to `true`, the host machine may still choose to delay sending commands.
    /// - Note: Setting this to `true` will immediately drain the buffer.
    public var sendCommandsImmediately: Bool {
        get { return autoflush.load(ordering: .sequentiallyConsistent) }
        set(newValue) {
            if newValue { self.channel.flush() }
            autoflush.store(newValue, ordering: .sequentiallyConsistent)
        }
    }
    /// Controls the permission of the connection to be able to have PubSub subscriptions or not.
    ///
    /// When set to `true`, this connection is allowed to create subscriptions.
    /// When set to `false`, this connection is not allowed to create subscriptions. Any potentially existing subscriptions will be removed.
    public var allowSubscriptions: Bool {
        get { self.allowPubSub.load(ordering: .sequentiallyConsistent) }
        set(newValue) {
            self.allowPubSub.store(newValue, ordering: .sequentiallyConsistent)
            // if we're subscribed, and we're not allowed to be in pubsub, end our subscriptions
            guard self.isSubscribed && !self.allowPubSub.load(ordering: .sequentiallyConsistent) else { return }
            _ = EventLoopFuture<Void>.whenAllComplete([
                self.unsubscribe(),
                self.punsubscribe()
            ], on: self.eventLoop)
        }
    }
    /// A closure to invoke when the connection closes unexpectedly.
    ///
    /// An unexpected closure is when the connection is closed by any other method than by calling `close(logger:)`.
    public var onUnexpectedClosure: (() -> Void)?

    internal let channel: Channel
    private let systemContext: Context
    private var logger: Logger { self.systemContext }

    private let autoflush = ManagedAtomic<Bool>(true)
    private let allowPubSub = ManagedAtomic<Bool>(true)
    private let _stateLock = NIOLock()
    private var _state = ConnectionState.open
    private var state: ConnectionState {
        get { return _stateLock.withLock { self._state } }
        set(newValue) { _stateLock.withLockVoid { self._state = newValue } }
    }

    deinit {
        if isConnected {
            assertionFailure("close() was not called before deinit!")
            self.logger.warning("connection was not properly shutdown before deinit")
        }
    }

    internal init(configuredRESPChannel: Channel, context: Context) {
        self.channel = configuredRESPChannel
        // there is a mix of verbiage here as the API is forward thinking towards "baggage context"
        // while right now it's just an alias of a 'Logging.logger'
        // in the future this will probably be a property _on_ the context
        var logger = context
        logger[metadataKey: RedisLogging.MetadataKeys.connectionID] = "\(self.id.description)"
        self.systemContext = logger

        RedisMetrics.activeConnectionCount.increment()
        RedisMetrics.totalConnectionCount.increment()

        // attach a callback to the channel to capture situations where the channel might be closed out from under
        // the connection
        self.channel.closeFuture.whenSuccess {
            // if our state is still open, that means we didn't cause the closeFuture to resolve.
            // update state, metrics, and logging
            guard self.state.isConnected else { return }

            self.state = .closed
            self.logger.error("connection was closed unexpectedly")
            RedisMetrics.activeConnectionCount.decrement()
            self.onUnexpectedClosure?()
        }

        self.logger.trace("connection created")
    }

    internal enum ConnectionState {
        case open
        case pubsub(RedisPubSubHandler)
        case shuttingDown
        case closed

        var isConnected: Bool {
            switch self {
            case .open, .pubsub: return true
            default: return false
            }
        }
        var isSubscribed: Bool {
            guard case .pubsub = self else { return false }
            return true
        }
    }
}

// MARK: Sending Commands

extension RedisConnection {
    /// Sends the command with the provided arguments to Redis.
    ///
    /// See `RedisClient.send(command:with:)`.
    /// - Note: The timing of when commands are actually sent to Redis can be controlled with the `RedisConnection.sendCommandsImmediately` property.
    /// - Returns: A `NIO.EventLoopFuture` that resolves with the command's result stored in a `RESPValue`.
    ///     If a `RedisError` is returned, the future will be failed instead.
    public func send(command: String, with arguments: [RESPValue]) -> EventLoopFuture<RESPValue> {
        self.eventLoop.flatSubmit {
            return self.send(command: command, with: arguments, context: nil)
        }
    }

    internal func send(
        command: String,
        with arguments: [RESPValue],
        context: Context?
    ) -> EventLoopFuture<RESPValue> {
        self.eventLoop.preconditionInEventLoop()

        let logger = self.prepareLoggerForUse(context)

        guard self.isConnected else {
            let error = RedisClientError.connectionClosed
            logger.warning("\(error.localizedDescription)")
            return self.channel.eventLoop.makeFailedFuture(error)
        }
        logger.trace("received command request")

        logger.debug("sending command", metadata: [
            RedisLogging.MetadataKeys.commandKeyword: "\(command)",
            RedisLogging.MetadataKeys.commandArguments: "\(arguments)"
        ])

        var message: [RESPValue] = [.init(bulk: command)]
        message.append(contentsOf: arguments)

        let promise = channel.eventLoop.makePromise(of: RESPValue.self)
        let command = RedisCommand(
            message: .array(message),
            responsePromise: promise
        )

        let startTime = DispatchTime.now().uptimeNanoseconds
        promise.futureResult.whenComplete { result in
            let duration = DispatchTime.now().uptimeNanoseconds - startTime
            RedisMetrics.commandRoundTripTime.recordNanoseconds(duration)

            // log data based on the result
            switch result {
            case let .failure(error):
                logger.error("command failed", metadata: [
                    RedisLogging.MetadataKeys.error: "\(error.localizedDescription)"
                ])

            case let .success(value):
                logger.debug("command succeeded", metadata: [
                    RedisLogging.MetadataKeys.commandResult: "\(value)"
                ])
            }
        }

        defer { logger.trace("command sent") }

        if self.sendCommandsImmediately {
            return channel.writeAndFlush(command).flatMap { promise.futureResult }
        } else {
            return channel.write(command).flatMap { promise.futureResult }
        }
    }
}

// MARK: Closing a Connection

extension RedisConnection {
    /// Sends a `QUIT` command to Redis, then closes the `NIO.Channel` that supports this connection.
    ///
    /// See [https://redis.io/commands/quit](https://redis.io/commands/quit)
    /// - Important: Regardless if the returned `NIO.EventLoopFuture` fails or succeeds - after calling this method the connection should no longer be
    ///     used for sending commands to Redis.
    /// - Parameter logger: An optional logger instance to use while trying to close the connection.
    ///         If one is not provided, the pool will use its default logger.
    /// - Returns: A `NIO.EventLoopFuture` that resolves when the connection has been closed.
    @discardableResult
    public func close(logger: Logger? = nil) -> EventLoopFuture<Void> {
        let logger = self.prepareLoggerForUse(logger)

        guard self.isConnected else {
            // return the channel's close future, which is resolved as the last step in channel shutdown
            logger.info("received duplicate request to close connection")
            return self.channel.closeFuture
        }
        logger.trace("received request to close the connection")

        // we're now in a shutdown state, starting with the command queue.
        self.state = .shuttingDown

        let notification = self.sendQuitCommand(logger: logger) // send "QUIT" so that all the responses are written out
            .flatMap { self.closeChannel() } // close the channel from our end

        notification.whenFailure {
            logger.error("error while closing connection", metadata: [
                RedisLogging.MetadataKeys.error: "\($0)"
            ])
        }
        notification.whenSuccess {
            self.state = .closed
            logger.trace("connection is now closed")
            RedisMetrics.activeConnectionCount.decrement()
        }

        return notification
    }

    /// Bypasses everything for a normal command and explicitly just sends a "QUIT" command to Redis.
    /// - Note: If the command fails, the `NIO.EventLoopFuture` will still succeed - as it's not critical for the command to succeed.
    private func sendQuitCommand(logger: Logger) -> EventLoopFuture<Void> {
        let promise = channel.eventLoop.makePromise(of: RESPValue.self)
        let command = RedisCommand(
            message: .array([RESPValue(bulk: "QUIT")]),
            responsePromise: promise
        )

        logger.trace("sending QUIT command")

        return channel.writeAndFlush(command) // write the command
            .flatMap { promise.futureResult } // chain the callback to the response's
            .map { _ in logger.trace("sent QUIT command") } // ignore the result's value
            .recover { _ in logger.debug("recovered from error sending QUIT") } // if there's an error, just return to void
    }

    /// Attempts to close the `NIO.Channel`.
    /// SwiftNIO throws a `NIO.EventLoopError.shutdown` if the channel is already closed,
    /// so that case is captured to let this method's `NIO.EventLoopFuture` still succeed.
    private func closeChannel() -> EventLoopFuture<Void> {
        let promise = self.channel.eventLoop.makePromise(of: Void.self)

        self.channel.close(promise: promise)

        // if we succeed, great, if not - check the error that happened
        return promise.futureResult
            .flatMapError { error in
                guard let e = error as? EventLoopError else {
                    return self.eventLoop.makeFailedFuture(error)
                }

                // if the error is that the channel is already closed, great - just succeed.
                // otherwise, fail the chain
                switch e {
                case .shutdown: return self.eventLoop.makeSucceededFuture(())
                default: return self.eventLoop.makeFailedFuture(e)
                }
            }
    }
}

// MARK: Logging

extension RedisConnection {
    public func logging(to logger: Logger) -> RedisClient {
        return UserContextRedisClient(client: self, context: self.prepareLoggerForUse(logger))
    }

    private func prepareLoggerForUse(_ logger: Logger?) -> Logger {
        guard var logger = logger else { return self.logger }
        logger[metadataKey: RedisLogging.MetadataKeys.connectionID] = "\(self.id)"
        return logger
    }
}

// MARK: Entering PubSub

extension RedisConnection {
    public func subscribe(
        to channels: [RedisChannelName],
        messageReceiver receiver: @escaping RedisSubscriptionMessageReceiver,
        onSubscribe subscribeHandler: RedisSubscriptionChangeHandler?,
        onUnsubscribe unsubscribeHandler: RedisSubscriptionChangeHandler?
    ) -> EventLoopFuture<Void> {
        return self._subscribe(.channels(channels), receiver, subscribeHandler, unsubscribeHandler, nil)
    }

    public func psubscribe(
        to patterns: [String],
        messageReceiver receiver: @escaping RedisSubscriptionMessageReceiver,
        onSubscribe subscribeHandler: RedisSubscriptionChangeHandler? = nil,
        onUnsubscribe unsubscribeHandler: RedisSubscriptionChangeHandler? = nil
    ) -> EventLoopFuture<Void> {
        return self._subscribe(.patterns(patterns), receiver, subscribeHandler, unsubscribeHandler, nil)
    }

    internal func subscribe(
        to channels: [RedisChannelName],
        messageReceiver receiver: @escaping RedisSubscriptionMessageReceiver,
        onSubscribe subscribeHandler: RedisSubscriptionChangeHandler?,
        onUnsubscribe unsubscribeHandler: RedisSubscriptionChangeHandler?,
        context: Context?
    ) -> EventLoopFuture<Void> {
        return self._subscribe(.channels(channels), receiver, subscribeHandler, unsubscribeHandler, context)
    }

    internal func psubscribe(
        to patterns: [String],
        messageReceiver receiver: @escaping RedisSubscriptionMessageReceiver,
        onSubscribe subscribeHandler: RedisSubscriptionChangeHandler?,
        onUnsubscribe unsubscribeHandler: RedisSubscriptionChangeHandler?,
        context: Context?
    ) -> EventLoopFuture<Void> {
        return self._subscribe(.patterns(patterns), receiver, subscribeHandler, unsubscribeHandler, context)
    }

    private func _subscribe(
        _ target: RedisSubscriptionTarget,
        _ receiver: @escaping RedisSubscriptionMessageReceiver,
        _ onSubscribe: RedisSubscriptionChangeHandler?,
        _ onUnsubscribe: RedisSubscriptionChangeHandler?,
        _ logger: Logger?
    ) -> EventLoopFuture<Void> {
        let logger = self.prepareLoggerForUse(logger)

        logger.trace("received subscribe request")

        // if we're closed, just error out
        guard self.state.isConnected else { return self.eventLoop.makeFailedFuture(RedisClientError.connectionClosed) }

        // if we're not allowed to to subscribe, then fail
        guard self.allowSubscriptions else {
            return self.eventLoop.makeFailedFuture(RedisClientError.pubsubNotAllowed)
        }

        logger.trace("adding subscription", metadata: [
            RedisLogging.MetadataKeys.pubsubTarget: "\(target.debugDescription)"
        ])

        // if we're in pubsub mode already, great - add the subscriptions
        guard case let .pubsub(handler) = self.state else {
            logger.debug("not in pubsub mode, moving to pubsub mode")
            // otherwise, add it to the pipeline, add the subscriptions, and update our state after it was successful
            return self.channel.pipeline
                .addRedisPubSubHandler()
                .flatMap { handler in
                    logger.trace("handler added, adding subscription")
                    return handler
                        .addSubscription(for: target, messageReceiver: receiver, onSubscribe: onSubscribe, onUnsubscribe: onUnsubscribe)
                        .flatMapError { error in
                            logger.debug(
                                "failed to add subscriptions that triggered pubsub mode. removing handler",
                                metadata: [
                                    RedisLogging.MetadataKeys.error: "\(error.localizedDescription)"
                                ]
                            )
                            // if there was an error, no subscriptions were made
                            // so remove the handler and propogate the error to the caller by rethrowing it
                            return self.channel.pipeline
                                .removeRedisPubSubHandler(handler)
                                .flatMapThrowing { throw error }
                        }
                        // success, return the handler
                        .map { _ in
                            logger.trace("successfully entered pubsub mode")
                            return handler
                        }
                }
                // success, update our state
                .map { (handler: RedisPubSubHandler) in
                    self.state = .pubsub(handler)
                    logger.debug("the connection is now in pubsub mode")
                }
        }

        // add the subscription and just ignore the subscription count
        return handler
            .addSubscription(for: target, messageReceiver: receiver, onSubscribe: onSubscribe, onUnsubscribe: onUnsubscribe)
            .map { _ in logger.trace("subscription added") }
    }
}

// MARK: Leaving PubSub

extension RedisConnection {
    public func unsubscribe(from channels: [RedisChannelName]) -> EventLoopFuture<Void> {
        return self._unsubscribe(.channels(channels), nil)
    }

    public func punsubscribe(from patterns: [String]) -> EventLoopFuture<Void> {
        return self._unsubscribe(.patterns(patterns), nil)
    }

    internal func unsubscribe(from channels: [RedisChannelName], context: Context?) -> EventLoopFuture<Void> {
        return self._unsubscribe(.channels(channels), context)
    }

    internal func punsubscribe(from patterns: [String], context: Context?) -> EventLoopFuture<Void> {
        return self._unsubscribe(.patterns(patterns), context)
    }

    private func _unsubscribe(_ target: RedisSubscriptionTarget, _ logger: Logger?) -> EventLoopFuture<Void> {
        let logger = self.prepareLoggerForUse(logger)

        logger.trace("received unsubscribe request")

        // if we're closed, just error out
        guard self.state.isConnected else { return self.eventLoop.makeFailedFuture(RedisClientError.connectionClosed) }

        // if we're not in pubsub mode, then we just succeed as a no-op
        guard case let .pubsub(handler) = self.state else {
            // but we still assert just to give some notification to devs at debug
            logger.notice("received request to unsubscribe while not in pubsub mode", metadata: [
                RedisLogging.MetadataKeys.pubsubTarget: "\(target.debugDescription)"
            ])
            return self.eventLoop.makeSucceededFuture(())
        }

        logger.trace("removing subscription", metadata: [
            RedisLogging.MetadataKeys.pubsubTarget: "\(target.debugDescription)"
        ])

        // remove the subscription
        return handler.removeSubscription(for: target)
            .flatMap {
                // if we still have subscriptions, just succeed this request
                guard $0 == 0 else {
                    logger.debug("subscription removed, but still have active subscription count", metadata: [
                        RedisLogging.MetadataKeys.subscriptionCount: "\($0)",
                        RedisLogging.MetadataKeys.pubsubTarget: "\(target.debugDescription)"
                    ])
                    return self.eventLoop.makeSucceededFuture(())
                }
                logger.debug("subscription removed, with no current active subscriptions. leaving pubsub mode")
                // otherwise, remove the handler and update our state
                return self.channel.pipeline
                    .removeRedisPubSubHandler(handler)
                    .map {
                        self.state = .open
                        logger.debug("connection is now open to all commands")
                    }
            }
    }
}
