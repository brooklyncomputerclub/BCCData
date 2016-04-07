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
     - Create object for entity (using dictionary?)
     - Update object for entity by ID (using dictionary or existing object?)
 
     - Parameter bindings instead of baked-in text for prepared statement SQL?
     - Some sort of scheme for prepared statement caching?
     - Quicker way to add columns to an entity
     - Coercion of SQL types to objects for entity properties (using Mantle-style transformation?)
     - Confirmation of type validity for find query values?
     - Default column values
     - Relationships/foreign keys?
     - Swift integration?
     - Versioning/handle DB incompatibility?
     - How to deal with compound primary keys?
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

- (id<BCCSQLObject>)findObjectForEntityName:(NSString *)entityName primaryKeyValue:(id)primaryKeyValue;
- (NSArray<BCCSQLObject> *)findObjectsForEntityName:(NSString *)entityName withPredicate:(NSPredicate *)predicate;

- (void)deleteObjectForEntityName:(NSString *)entityName primaryKeyValue:(id)primaryKeyValue;
- (void)deleteObjectsForEntityName:(NSString *)entityName withPredicate:(NSPredicate *)predicate;

@end


@interface BCCSQLEntity : NSObject

@property (strong, nonatomic) NSString *name;
@property (strong, nonatomic) NSString *tableName;
@property (strong, nonatomic) NSString *primaryKey;
@property (nonatomic) Class<BCCSQLObject> instanceClass;

- (instancetype)initWithName:(NSString *)name;

- (void)addColumn:(BCCSQLColumn *)column;
- (BCCSQLColumn *)columnForName:(NSString *)columnName;

@end


@interface BCCSQLColumn : NSObject

@property (strong, nonatomic) NSString *name;
@property (nonatomic) BCCSQLType sqlType;
@property (strong, nonatomic) NSString *propertyKeyPath;

@property (nonatomic) BOOL nonNull;
@property (nonatomic) BOOL unique;

- (instancetype)initWithName:(NSString *)name;

@end


@interface BCCSQLTestModelObject : NSObject <BCCSQLObject>

@property (nonatomic) NSInteger objectID;
@property (strong, nonatomic) NSString *name;

+ (void)performTest;

@end

