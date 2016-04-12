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
     - Create object for entity (using dictionary?)
     - Update object for entity by ID (using dictionary or existing object?)
 
     - Get rid of entityForName/registerEntity, rely only on entity provided by model class, add methods to create tables from model object classes?
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

@protocol BCCSQLModelObject <NSObject>

+ (BCCSQLEntity *)entity;

+ (instancetype)modelObjectWithDictionary:(NSDictionary *)dictionaryValue;

- (instancetype)initWithDictionary:(NSDictionary *)dictionary;

- (id)valueForPropertyKey:(NSString *)propertyKey;
- (void)markPropertyKeyChanged:(NSString *)key;
- (NSSet <NSString *> *)changedPropertyKeys;
- (void)resetChangedPropertyKeys;

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
- (void)createOrUpdateModelObject:(id <BCCSQLModelObject>)modelObject;

- (id<BCCSQLModelObject>)findObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass primaryKeyValue:(id)primaryKeyValue;
- (NSArray<BCCSQLModelObject> *)findObjectsOfClass:(Class<BCCSQLModelObject>)modelObjectClass withPredicate:(NSPredicate *)predicate;

- (void)deleteObject:(id<BCCSQLModelObject>)object;
- (void)deleteObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass primaryKeyValue:(id)primaryKeyValue;
- (void)deleteObjectsOfClass:(Class<BCCSQLModelObject>)modelObjectClass withPredicate:(NSPredicate *)predicate;

@end


@interface BCCSQLEntity : NSObject

@property (strong, nonatomic) NSString *name;
@property (strong, nonatomic) NSString *tableName;
@property (nonatomic) Class<BCCSQLModelObject> instanceClass;
@property (strong, nonatomic) NSString *primaryKey;

@property (nonatomic, readonly) BCCSQLProperty *primaryKeyColumn;

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

- (id)valueForPropertyKey:(NSString *)key;
- (void)markPropertyKeyChanged:(NSString *)key;
- (NSArray <NSString *> *)changedPropertyKeys;
- (void)resetChangedPropertyKeys;

@end


@interface BCCSQLTestModelObject : BCCSQLModelObject

@property (nonatomic) NSInteger objectID;
@property (strong, nonatomic) NSString *name;

+ (void)performTest;

@end
