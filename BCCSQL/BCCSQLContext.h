//
//  BCCSQLContext.h
//  Places
//
//  Created by Laurence Andersen on 4/4/16.
//  Copyright © 2016 Brooklyn Computer Club. All rights reserved.
//

#import <Foundation/Foundation.h>

@class BCCSQLEntity;
@class BCCSQLProperty;

/* 
     TO DO:
     
     NOW:
     - Create object for entity (using dictionary?)
     - Find multiple objects using (optional) predicate
     - Delete multiple objects using (optional) predicate
     - Dry up some of the SQL string generation code?
     - Better type coercion/coercion incompatibility handling
     - Get rid of entityForName/registerEntity, rely only on entity provided by model class, add methods to create tables from model object classes?
 
     MAYBE NOW:
     - Queuing
     - Transactions
     - Observation
 
     LATER:
     - Some sort of scheme for prepared statement caching?
     - Quicker way to add columns to an entity
     - Default column values
     - Relationships/foreign keys?
     - Swift integration?
     - Versioning/handle DB incompatibility?
*/

typedef NS_ENUM(NSUInteger, BCCSQLType) {
    BCCSQLTypeText,
    BCCSQLTypeNumeric,
    BCCSQLTypeInteger,
    BCCSQLTypeReal,
    BCCSQLTypeBlob
};

@protocol BCCSQLModelObject <NSObject>

+ (BCCSQLEntity *)entity;

+ (instancetype)modelObjectWithDictionary:(NSDictionary *)dictionaryValue;

- (instancetype)initWithDictionary:(NSDictionary *)dictionary;

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
- (void)createModelObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass withDictionary:(NSDictionary *)dictionary; // TO DO
- (id <BCCSQLModelObject>)createOrUpdateModelObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass withDictionary:(NSDictionary <NSString *, id> *)dictionary primaryKeyValue:(id)primaryKeyValue;

- (id<BCCSQLModelObject>)findObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass primaryKeyValue:(id)primaryKeyValue;
- (NSArray<BCCSQLModelObject> *)findObjectsOfClass:(Class<BCCSQLModelObject>)modelObjectClass withPredicate:(NSPredicate *)predicate; // TO DO

- (void)deleteObject:(id<BCCSQLModelObject>)object;
- (void)deleteObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass primaryKeyValue:(id)primaryKeyValue;
- (void)deleteObjectsOfClass:(Class<BCCSQLModelObject>)modelObjectClass withPredicate:(NSPredicate *)predicate; // TO DO

@end


@interface BCCSQLEntity : NSObject

@property (strong, nonatomic) NSString *name;
@property (strong, nonatomic) NSString *tableName;
@property (nonatomic) Class<BCCSQLModelObject> instanceClass;
@property (strong, nonatomic) NSString *primaryKey;

@property (nonatomic, readonly) BCCSQLProperty *primaryKeyProperty;

- (instancetype)initWithName:(NSString *)name;

- (void)addProperty:(BCCSQLProperty *)column;
- (BCCSQLProperty *)propertyForKey:(NSString *)key;
- (BCCSQLProperty *)propertyForColumnName:(NSString *)columnName;

@end


@interface BCCSQLProperty : NSObject

@property (strong, nonatomic) NSString *columnName;
@property (nonatomic) BCCSQLType sqlType;
@property (strong, nonatomic) NSString *propertyKey;

@property (nonatomic) BOOL nonNull;
@property (nonatomic) BOOL unique;

- (instancetype)initWithColumnName:(NSString *)name;

@end


@interface BCCSQLModelObject : NSObject <BCCSQLModelObject>

@end


@interface BCCSQLTestModelObject : BCCSQLModelObject

@property (nonatomic) NSInteger objectID;
@property (strong, nonatomic) NSString *name;

+ (void)performTest;

@end
