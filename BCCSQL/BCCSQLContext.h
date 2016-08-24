//
//  BCCSQLContext.h
//  Places
//
//  Created by Laurence Andersen on 4/4/16.
//  Copyright © 2016 Brooklyn Computer Club. All rights reserved.
//

#import <Foundation/Foundation.h>

@class BCCSQLContext;
@class BCCSQLEntity;
@class BCCSQLProperty;

/* 
     TO DO:
     
     NOW:
     - First class Transaction objects?
     - Sort descriptors
     - Relationships/foreign keys?
     - Better type coercion/coercion incompatibility handling
     - Observation
     - In-Memory Object Cache
 
     LATER:
     - Get rid of entityForName/registerEntity, rely only on entity provided by model class, add methods to create tables from model object classes?
     - Better/more thorough error reporting
     - Some sort of scheme for prepared statement caching?
     - Quicker way to add columns to an entity
     - Default column values
     - Swift integration?
     - Versioning/handle DB incompatibility?
     - CloudKit
*/

typedef void (^BCCSQLWorkBlock)(BCCSQLContext *context);

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
- (id<BCCSQLModelObject>)createModelObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass withDictionary:(NSDictionary *)dictionary;
- (id<BCCSQLModelObject>)updateModelObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass withDictionary:(NSDictionary *)dictionary primaryKeyValue:(id<BCCSQLModelObject>)primaryKeyValue;
- (id<BCCSQLModelObject>)createOrUpdateModelObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass withDictionary:(NSDictionary <NSString *, id> *)dictionary;

- (id<BCCSQLModelObject>)findModelObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass primaryKeyValue:(id)primaryKeyValue;
- (NSArray<BCCSQLModelObject> *)findModelObjectsOfClass:(Class<BCCSQLModelObject>)modelObjectClass;
- (NSArray<BCCSQLModelObject> *)findModelObjectsOfClass:(Class<BCCSQLModelObject>)modelObjectClass withPredicate:(NSPredicate *)predicate;

- (void)deleteObject:(id<BCCSQLModelObject>)object;
- (void)deleteObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass primaryKeyValue:(id)primaryKeyValue;
- (void)deleteObjectsOfClass:(Class<BCCSQLModelObject>)modelObjectClass;
- (void)deleteObjectsOfClass:(Class<BCCSQLModelObject>)modelObjectClass withPredicate:(NSPredicate *)predicate;

// Queuing
- (void)performWorkBlock:(BCCSQLWorkBlock)workBlock;
- (void)performWorkBlock:(BCCSQLWorkBlock)workBlock andWait:(BOOL)wait;
- (void)performWorkBlock:(BCCSQLWorkBlock)workBlock andWait:(BOOL)wait error:(NSError **)error;

@end


@interface BCCSQLEntity : NSObject

@property (strong, nonatomic) NSString *name;
@property (strong, nonatomic) NSString *city;
@property (strong, nonatomic) NSString *tableName;
@property (nonatomic) Class<BCCSQLModelObject> instanceClass;
@property (nonatomic, readonly) NSString *primaryKeyPropertyKey;

@property (nonatomic, readonly) BCCSQLProperty *primaryKeyProperty;

- (instancetype)initWithName:(NSString *)name;

- (void)addProperty:(BCCSQLProperty *)column primaryKey:(BOOL)isPrimaryKey;
- (BCCSQLProperty *)propertyForKey:(NSString *)key;
- (BCCSQLProperty *)propertyForColumnName:(NSString *)columnName;

@end


@interface BCCSQLProperty : NSObject

@property (strong, nonatomic) NSString *propertyKey;
@property (strong, nonatomic) NSString *columnName;
@property (nonatomic) BCCSQLType sqlType;

@property (nonatomic) BOOL nonNull;
@property (nonatomic) BOOL unique;

- (instancetype)initWithColumnName:(NSString *)name;

@end


@interface BCCSQLModelObject : NSObject <BCCSQLModelObject>

@end


@interface BCCSQLTestModelObject : BCCSQLModelObject

@property (nonatomic) NSInteger objectID;
@property (strong, nonatomic) NSString *name;
@property (strong, nonatomic) NSString *city;

+ (void)performTest;

@end


