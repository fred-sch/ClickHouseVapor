//
//  ClickHouseModel.swift
//  ClickHouseVapor
//
//  Created by Patrick Zippenfenig on 2020-11-10.
//

import Foundation
import Vapor
import ClickHouseNIO

public protocol ClickHouseModel: AnyObject {
    static var engine: ClickHouseEngine { get }
    init()
}

extension ClickHouseModel {
    /// Get the number of rows. In case only some rows are populated (e.g. only certain ), the first column with more than 0 rows is considered.
    public var count: Int {
        return properties.first(where: {$0.count > 0})?.count ?? 0
    }
    
    /// Only include column rows where the isIncluded array is true. This shrinks the amount of data inside the table result.
    public func filter(_ isIncluded: [Bool]) {
        precondition(isIncluded.count == count)
        properties.forEach {
            $0.filter(isIncluded)
        }
    }
    
    /// Combine two results of the same table by appending each row of every columns together.
    public func append(_ other: Self) {
        zip(properties, other.properties).forEach {
            $0.0.append($0.1.getClickHouseArray())
        }
    }
    
    /// Reserve space in all data columns.
    public func reserveCapacity(_ capacity: Int) {
        properties.forEach {
            $0.reserveCapacity(capacity)
        }
    }
    
    /// Get access to the internal Property wrappers using Reflection. This way we can apply data from select queries to the correct row.
    internal var properties: [ClickHouseColumnConvertible] {
        return Mirror(reflecting: self).children.compactMap {
            $0.value as? ClickHouseColumnConvertible
        }
    }
    
    /// Create the table in the database.
    public static func createTable(on connection: ClickHouseConnectionProtocol, engine: ClickHouseEngine? = nil) -> EventLoopFuture<Void> {
        let fields = Self.init().properties
        let engine = engine ?? Self.engine
        let query = engine.createTableQuery(columns: fields)
        connection.logger.debug("\(query)")
        
        if engine.isUsingCluster {
            // cluster operation, return some information
            return connection.query(sql: query).transform(to: ())
        } else {
            return connection.command(sql: query)
        }
    }
    
    public func insert(on connection: ClickHouseConnectionProtocol, engine: ClickHouseEngine? = nil)  -> EventLoopFuture<Void> {
        let fields = properties
        let engine = engine ?? Self.engine
        let data = fields.compactMap {
            return $0.count == 0 ? nil : ClickHouseColumn($0.key, $0.getClickHouseArray())
        }
        guard data.count > 0 else {
            // no values -> nothing to do
            return connection.eventLoop.makeSucceededFuture(())
        }
        
        return connection.insert(into: engine.tableWithDatabase, data: data)
    }
    
    /// Delete this table. This operation cannot be undone.
    public static func deleteTable(on connection: ClickHouseConnectionProtocol, engine: ClickHouseEngine? = nil) -> EventLoopFuture<Void> {
        let engine = engine ?? Self.engine
        if let cluster = engine.cluster {
            let query = "DROP TABLE IF EXISTS \(engine.tableWithDatabase) ON CLUSTER \(cluster)"
            connection.logger.info("\(query)")
            // deletes on a cluster, return some information
            return connection.query(sql: query).transform(to: ())
        } else {
            let query = "DROP TABLE IF EXISTS \(engine.tableWithDatabase)"
            connection.logger.info("\(query)")
            return connection.command(sql: query)
        }
    }
    
    /// Execute a SQL SELECT statemant and apply all returned columns to this entity
    public static func select(on connection: ClickHouseConnectionProtocol, sql: String) -> EventLoopFuture<Self> {
        connection.logger.debug("\(sql)")
        let this = Self.init()
        let properties = this.properties
        return connection.query(sql: sql).flatMapThrowing { res -> Self in
            try res.columns.forEach { column in
                guard let prop = properties.first(where: {$0.key == column.name}) else {
                    return
                }
                try prop.setClickHouseArray(column.values)
            }
            return this
        }
    }
    
    /// Query data from database.
    /// If final ist set to true, all duplicate merges are ensured, but perfmrance suffers
    public static func select(on connection: ClickHouseConnectionProtocol, fields: [String]? = nil, final: Bool = false, where whereClause: String? = nil, order: String? = nil, limit: Int? = nil, offset: Int? = nil, engine: ClickHouseEngine? = nil) -> EventLoopFuture<Self> {
        
        let engine = engine ?? Self.engine
        let fields = fields ?? Self.init().properties.map { "`\($0.key)`" }
        
        var sql = "SELECT "
        sql += fields.joined(separator: ",")
        sql += "FROM \(engine.tableWithDatabase)"
        if final {
            sql += " FINAL"
        }
        if let whereClause = whereClause {
            sql += " WHERE \(whereClause)"
        }
        if let order = order {
            sql += " ORDER BY \(order)"
        }
        if let limit = limit {
            sql += " LIMIT \(limit)"
            if let offset = offset {
                sql += ",\(offset)"
            }
        }
        return select(on: connection, sql: sql)
    }
}
