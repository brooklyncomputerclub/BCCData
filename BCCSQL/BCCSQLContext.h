//
//  BCCSQLContext.h
//  Places
//
//  Created by Laurence Andersen on 4/4/16.
//  Copyright © 2016 Brooklyn Computer Club. All rights reserved.
//

#import <Foundation/Foundation.h>

@class BCCSQLEntity;
@class BCCSQLColumn;
@protocol BCCSQLObject;

/* 
     TO DO:
     - How to deal with integer primary keys/autoincrement and compound primary keys
     - Enum for SQL types?
     - Create object for entity (using dictionary?)
     - Update object for entity by ID (using dictionary or existing object?)
     - Find object for entity by ID
     - Find object for entity using predicate
     - Delete object by ID
     - Quicker way to add columns to an entity
     - Coercion of SQL types to objects for entity properties (using Mantle-style transformation?)
     - Relationships/foreign keys?
     - Swift integration?
*/

typedef NS_ENUM(NSUInteger, BCCSQLType) {
    BCCSQLTypeText,
    BCCSQLTypeNumeric,
    BCCSQLTypeInteger,
    BCCSQLTypeReal,
    BCCSQLTypeBlob
};

@protocol BCCSQLObject <NSObject>

@end


@interface BCCSQLContext : NSObject

@property (nonatomic, readonly) NSString *databasePath;

// Initialization
- (instancetype)initWithDatabasePath:(NSString *)databasePath;

// Database Configuration
- (void)initializeDatabase;

- (void)registerEntity:(BCCSQLEntity *)entity;
- (BCCSQLEntity *)entityForName:(NSString *)entityName;

// CRUD
- (id<BCCSQLObject>)createOrUpdateObjectForEntityName:(NSString *)entityName usingDictionary:(NSDictionary *)dictionary;
- (id<BCCSQLObject>)findObjectForEntityName:(NSString *)entityName primaryKey:(id)primaryKey;
- (NSArray<BCCSQLObject> *)findObjectsForEntityName:(NSString *)entityName withPredicate:(NSPredicate *)predicate;
- (void)deleteObjectForEntityName:(NSString *)entityName;

@end


@interface BCCSQLEntity : NSObject

@property (strong, nonatomic) NSString *name;
@property (strong, nonatomic) NSString *tableName;
@property (nonatomic) Class<BCCSQLObject> instanceClass;

- (instancetype)initWithName:(NSString *)name;

- (void)addColumn:(BCCSQLColumn *)column;
- (BCCSQLColumn *)columnForName:(NSString *)columnName;

@end


@interface BCCSQLColumn : NSObject

@property (strong, nonatomic) NSString *name;
@property (nonatomic) BCCSQLType sqlType;
@property (strong, nonatomic) NSString *propertyKeyPath;

@property (nonatomic) BOOL primaryKey;
@property (nonatomic) BOOL nonNull;
@property (nonatomic) BOOL unique;

- (instancetype)initWithName:(NSString *)name;

@end


@interface BCCSQLTestModelObject : NSObject <BCCSQLObject>

@property (nonatomic) NSInteger objectID;
@property (strong, nonatomic) NSString *name;

+ (void)performTest;

@end

