//
//  BCCSQLContext.m
//  Places
//
//  Created by Laurence Andersen on 4/4/16.
//  Copyright © 2016 Brooklyn Computer Club. All rights reserved.
//

#import "BCCSQLContext.h"
#import "NSString+BCCAdditions.h"
#import "NSFileManager+BCCAdditions.h"
#import <sqlite3.h>


@interface BCCSQLContext ()

@property (strong, nonatomic) NSString *databasePath;

@property (nonatomic) sqlite3 *databaseConnection;

@property (strong, nonatomic) NSMutableDictionary<NSString *, BCCSQLEntity *> *entities;

- (void)createEntityTables;

- (sqlite3_stmt *)prepareSQLStatement:(NSString *)SQLString error:(NSError **)error;
- (id<BCCSQLModelObject>)nextObjectFromStatement:(sqlite3_stmt *)statement forEntity:(BCCSQLEntity *)entity error:(NSError **)error;

@end


@interface BCCSQLEntity ()

@property (strong, nonatomic) NSMutableArray<BCCSQLProperty *> *properties;

@property (nonatomic, readonly) NSString *createTableSQL;

- (NSPredicate *)primaryKeyPredicateForValue:(id)value;

@end


@interface BCCSQLProperty ()

@property (nonatomic, readonly) NSString *columnDefinitionSQL;

@end


@interface BCCSQLModelObject ()

@property (strong, nonatomic) NSMutableSet *changedKeys;

- (BOOL)validateChangeForPropertyKey:(nonnull NSString *)key value:(inout id  *)value;

@end


@implementation BCCSQLContext

#pragma mark - Initialization

- (instancetype)initWithDatabasePath:(NSString *)databasePath
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _databasePath = databasePath;
    
    _databaseConnection = NULL;
    
    return self;
}

#pragma mark - Database Configuration

- (void)initializeDatabase
{
    NSString *databasePath = self.databasePath;
    if (!databasePath) {
        return;
    }
    
    NSString *rootDirectory = [databasePath BCC_stringByRemovingLastPathComponent];
    if (!rootDirectory) {
        return;
    }
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:rootDirectory]) {
        [[NSFileManager defaultManager] BCC_recursivelyCreatePath:rootDirectory];
    }
    
    int err = sqlite3_open([databasePath UTF8String], &(_databaseConnection));
    if (err != SQLITE_OK) {
        NSLog(@"Error opening database: %s", sqlite3_errstr(err));
        return;
    }
    
    [self createEntityTables];
}

- (void)createEntityTables
{
    if (self.entities.count < 1 || self.databaseConnection == NULL) {
        return;
    }
    
    [self.entities enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, BCCSQLEntity * _Nonnull currentEntity, BOOL * _Nonnull stop) {
        NSString *currentCreateSQL = currentEntity.createTableSQL;
        if (!currentCreateSQL) {
            return;
        }
        
        char *errString;
        sqlite3_exec(_databaseConnection, [currentCreateSQL UTF8String], NULL, NULL, &errString);
        if (errString) {
            NSLog(@"Error creating table: %s", errString);
        }
    }];
}

#pragma mark - Entities

- (void)registerEntity:(BCCSQLEntity *)entity
{
    if (!_entities) {
        _entities = [[NSMutableDictionary alloc] init];
    }
    
    _entities[entity.name] = entity;
}

- (BCCSQLEntity *)entityForName:(NSString *)entityName
{
    return _entities[entityName];
}

#pragma mark - CRUD

- (void)createOrUpdateModelObject:(id <BCCSQLModelObject>)modelObject
{
    NSArray<NSString *> *changedPropertyKeys = modelObject.changedPropertyKeys.allObjects;
    if (changedPropertyKeys.count < 1) {
        return;
    }
    
    BCCSQLEntity *entity = [[modelObject class] entity];
    if (!entity) {
        return;
    }
    
    NSString *tableName = entity.tableName;
    if (!tableName) {
        return;
    }
    
    BCCSQLProperty *primaryKeyProperty = entity.primaryKeyColumn;
    if (!primaryKeyProperty) {
        return;
    }
    
    id primaryKeyValue = [modelObject valueForPropertyKey:primaryKeyProperty.propertyKey];
    if (!primaryKeyValue) {
        return;
    }
    
    BOOL exists = NO;
    id <BCCSQLModelObject> existingObject = [self findObjectOfClass:[modelObject class] primaryKeyValue:primaryKeyValue];
    if (existingObject) {
        exists = YES;
    }
    
    // TO DO: Maybe consider making the model object protocol return a
    // dictionary of changed keys and their values instead of doing this
    // all here.
    
    NSMutableString *columnsString = [[NSMutableString alloc] init];
    NSMutableString *valuesString = [[NSMutableString alloc] init];
    
    [changedPropertyKeys enumerateObjectsUsingBlock:^(NSString * _Nonnull currentPropertyKey, NSUInteger idx, BOOL * _Nonnull stop) {
        BCCSQLProperty *currentProperty = [entity propertyForKey:currentPropertyKey];
        if (!currentPropertyKey) {
            return;
        }
        
        NSString *columnName = currentProperty.columnName;
        if (!columnName) {
            return;
        }
        
        if (idx > 0) {
            [columnsString appendString:@", "];
        }
        
        if (exists) {
            [columnsString appendFormat:@"%@ = ?", columnName];
        } else {
            [columnsString appendString:columnName];
            
            if (idx > 0) {
                [valuesString appendString:@", "];
            }
            
            [valuesString appendString:@"?"];
        }
    }];
    
    NSString *createOrUpdateSQL = exists ? [NSString stringWithFormat:@"UPDATE %@ SET %@ WHERE %@ = ?", tableName, columnsString, primaryKeyProperty.columnName] : [NSString stringWithFormat:@"INSERT INTO %@ (%@) VALUES (%@)", tableName, columnsString, valuesString];
    NSLog(@"%@", createOrUpdateSQL);
    
    [modelObject resetChangedPropertyKeys];
}

- (id<BCCSQLModelObject>)findObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass primaryKeyValue:(id)primaryKeyValue
{
    if (!modelObjectClass) {
        return nil;
    }
    
    BCCSQLEntity *entity = [modelObjectClass entity];
    if (!entity) {
        return nil;
    }
    
    NSPredicate *primaryKeyPredicate = [entity primaryKeyPredicateForValue:primaryKeyValue];
    if (!primaryKeyPredicate) {
        return nil;
    }
    
    NSArray *foundObjects = [self findObjectsOfClass:modelObjectClass withPredicate:primaryKeyPredicate];
    return foundObjects.firstObject;
}

- (__kindof NSArray<BCCSQLModelObject> *)findObjectsOfClass:(Class<BCCSQLModelObject>)modelObjectClass withPredicate:(NSPredicate *)predicate
{
    if (!_databaseConnection || !modelObjectClass) {
        return nil;
    }
    
    BCCSQLEntity *entity = [modelObjectClass entity];
    if (!entity) {
        return nil;
    }
    
    NSString *tableName = entity.tableName;
    if (!tableName) {
        return nil;
    }
    
    NSInteger columnCount = entity.properties.count;
    NSMutableString *columnsString = [[NSMutableString alloc] init];
    
    [entity.properties enumerateObjectsUsingBlock:^(BCCSQLProperty * _Nonnull currentProperty, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *columnName = currentProperty.columnName;
        if (!columnName) {
            return;
        }
        
        [columnsString appendString:columnName];
        
        if (idx < (columnCount - 1)) {
            [columnsString appendString:@", "];
        }
    }];

    NSMutableString *selectString = [[NSMutableString alloc] initWithFormat:@"SELECT %@ FROM %@", columnsString, tableName];
    
    if (predicate) {
        [selectString appendFormat:@" WHERE %@", predicate.predicateFormat];
    }
    
    NSMutableArray<BCCSQLModelObject> *foundObjects = nil;
    id<BCCSQLModelObject> currentObject = nil;
    
    NSError *error;
    sqlite3_stmt *selectStatement = [self prepareSQLStatement:selectString error:&error];
    if (error != nil) {
        return nil;
    }
    
    foundObjects = [[NSMutableArray<BCCSQLModelObject> alloc] init];
    while (true) {
        currentObject = [self nextObjectFromStatement:selectStatement forEntity:entity error:NULL];
        if (currentObject) {
            [foundObjects addObject:currentObject];
        } else {
            break;
        }
    }
    
cleanup:
    sqlite3_finalize(selectStatement);
    
    return foundObjects;
}

- (void)deleteObject:(id<BCCSQLModelObject>)object
{
    if (!object) {
        return;
    }
    
    BCCSQLEntity *entity = [[object class] entity];
    NSString *entityName = entity.name;
    if (!entityName) {
        return;
    }
    
    NSString *primaryKeyPropertyPath = entity.primaryKeyColumn.propertyKey;
    if (!primaryKeyPropertyPath) {
        return;
    }
    
    
    id primaryKeyValue = [(NSObject *)object valueForKey:primaryKeyPropertyPath];
    if (!primaryKeyValue) {
        // TO DO: Exception? Error?
        return;
    }
    
    [self deleteObjectOfClass:[object class] primaryKeyValue:primaryKeyValue];
}

- (void)deleteObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass primaryKeyValue:(id)primaryKeyValue
{
    BCCSQLEntity *entity = [modelObjectClass entity];
    if (!entity) {
        return;
    }
    
    NSPredicate *primaryKeyPredicate = [entity primaryKeyPredicateForValue:primaryKeyValue];
    if (!primaryKeyPredicate) {
        return;
    }
    
    [self deleteObjectsOfClass:modelObjectClass withPredicate:primaryKeyPredicate];
}

- (void)deleteObjectsOfClass:(Class<BCCSQLModelObject>)modelObjectClass withPredicate:(NSPredicate *)predicate
{
    if (!_databaseConnection || !modelObjectClass) {
        return;
    }
    
    BCCSQLEntity *entity = [modelObjectClass entity];
    if (!entity) {
        return;
    }
    
    NSString *tableName = entity.tableName;
    if (!tableName) {
        return;
    }
    
    NSMutableString *deleteString = [[NSMutableString alloc] initWithFormat:@"DELETE FROM %@", tableName];
    
    if (predicate) {
        [deleteString appendFormat:@" WHERE %@", predicate.predicateFormat];
    }
    
    NSError *error;
    sqlite3_stmt *deleteStatement = [self prepareSQLStatement:deleteString error:&error];
    if (error != nil) {
        return;
    }

    // TO DO: Break this out into a block-based method?
    int stepResult;
    do {
        stepResult = sqlite3_step(deleteStatement);
    } while (stepResult == SQLITE_ROW);
    
    sqlite3_finalize(deleteStatement);
}

#pragma mark - Prepared Statements

- (sqlite3_stmt *)prepareSQLStatement:(NSString *)SQLString error:(NSError **)error
{
    if (!_databaseConnection || !SQLString) {
        return nil;
    }
    
    sqlite3_stmt *statement;
    int err = sqlite3_prepare_v2(_databaseConnection, [SQLString UTF8String], -1, &(statement), NULL);
    if (err != SQLITE_OK) {
        *error = [NSError errorWithDomain:@"BCCSQLContextSQLErrorDomain" code:err userInfo:nil];
        return nil;
    }
    
    *error = nil;
    return statement;
}

- (id<BCCSQLModelObject>)nextObjectFromStatement:(sqlite3_stmt *)statement forEntity:(BCCSQLEntity *)entity error:(NSError **)error
{
    if (!statement || !entity) {
        return nil;
    }
    
    int stepResult = sqlite3_step(statement);
    if (stepResult != SQLITE_ROW) {
        return nil;
    }
    
    NSObject<BCCSQLModelObject> *object = [[(Class)entity.instanceClass alloc] init];
    
    [entity.properties enumerateObjectsUsingBlock:^(BCCSQLProperty * _Nonnull currentProperty, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *propertyKey = currentProperty.propertyKey;
        
        id value = nil;
        
        // TO DO: Centralize type coercion logic somewhere?
        if (currentProperty.sqlType == BCCSQLTypeText) {
            const unsigned char *stringValue = sqlite3_column_text(statement, (int)idx);
            
            if (stringValue != NULL) {
                NSUInteger dataLength = sqlite3_column_bytes(statement, (int)idx);
                value = [[NSString alloc] initWithBytes:stringValue length:dataLength encoding:NSUTF8StringEncoding];
            }
        } else if (currentProperty.sqlType == BCCSQLTypeNumeric) {

        } else if (currentProperty.sqlType == BCCSQLTypeInteger) {
            int intValue = sqlite3_column_int(statement, (int)idx);
            value = [NSNumber numberWithInt:intValue];
        } else if (currentProperty.sqlType == BCCSQLTypeReal) {
            
        } else if (currentProperty.sqlType == BCCSQLTypeBlob) {
            
        }
        
        [object setValue:value forKey:propertyKey];
    }];
    
    [object resetChangedPropertyKeys];
    
    return object;
}

@end


@implementation BCCSQLEntity

- (instancetype)initWithName:(NSString *)name
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _name = name;
    
    return self;
}

- (NSString *)createTableSQL
{
    if (!self.tableName) {
        return nil;
    }
    
    NSMutableString *createString = [[NSMutableString alloc] initWithFormat:@"CREATE TABLE IF NOT EXISTS %@", self.tableName];
    NSMutableString *columnsString = [[NSMutableString alloc] init];
    
    NSInteger columnCount = self.properties.count;
    if (columnCount > 0) {
        [columnsString appendString:@"("];
    }
    
    __block BOOL hadValidColumns = NO;
    
    [self.properties enumerateObjectsUsingBlock:^(BCCSQLProperty * _Nonnull currentProperty, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *columnDefinitionSQL = currentProperty.columnDefinitionSQL;
        if (!columnDefinitionSQL) {
            return;
        }
        
        hadValidColumns = YES;
        [columnsString appendString:columnDefinitionSQL];
        
        if ([currentProperty.columnName isEqualToString:self.primaryKey]) {
            [columnsString appendString:@" PRIMARY KEY"];
        }
        
        if (idx < (columnCount - 1)) {
            [columnsString appendString:@", "];
        }
    }];
    
    if (hadValidColumns) {
        [columnsString appendString:@")"];
        [createString appendString:columnsString];
    }
    
    return createString;
}

- (NSPredicate *)primaryKeyPredicateForValue:(id)value
{
    NSString *primaryKey = self.primaryKey;
    if (!primaryKey) {
        return nil;
    }
    
    return [NSPredicate predicateWithFormat:@"%K == %@", primaryKey, value];
}

- (BCCSQLProperty *)primaryKeyColumn
{
    if (!self.primaryKey) {
        return nil;
    }
    
    return [self propertyForColumnName:self.primaryKey];
}

- (void)addProperty:(BCCSQLProperty *)property
{
    if (!property) {
        return;
    }
    
    if (!_properties) {
        _properties = [[NSMutableArray alloc] init];
    }
    
    [_properties addObject:property];
}

- (BCCSQLProperty *)propertyForKey:(NSString *)key
{
    if (!key || _properties.count < 1) {
        return nil;
    }
    
    NSArray *filteredProperties = [_properties filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"%K == %@", NSStringFromSelector(@selector(propertyKey)), key]];
    return filteredProperties.firstObject;
}

- (BCCSQLProperty *)propertyForColumnName:(NSString *)columnName
{
    if (!columnName || _properties.count < 1) {
        return nil;
    }
    
    NSArray *filteredProperties = [_properties filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"%K == %@", NSStringFromSelector(@selector(columnName)), columnName]];
    return filteredProperties.firstObject;
}

@end


@implementation BCCSQLProperty

- (instancetype)initWithColumnName:(NSString *)name
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    _columnName = name;
    
    return self;
}

- (NSString *)columnDefinitionSQL
{
    NSString *columnName = _columnName;
    if (!columnName) {
        return nil;
    }

    NSMutableString *createString = [[NSMutableString alloc] init];
    
    [createString appendString:columnName];
    
    NSString *typeString = nil;
    
    switch (self.sqlType) {
        case BCCSQLTypeText:
            typeString = @"TEXT";
            break;
        case BCCSQLTypeNumeric:
            typeString = @"NUMERIC";
            break;
        case BCCSQLTypeInteger:
            typeString = @"INTEGER";
            break;
        case BCCSQLTypeReal:
            typeString = @"REAL";
            break;
        default:
            break;
    }
    
    if (typeString != nil) {
        [createString appendFormat:@" %@", typeString];
    }

    if (self.nonNull) {
        [createString appendString:@" NOT NULL"];
    }
    
    if (self.unique) {
        [createString appendString:@" UNIQUE"];
    }
    
    return createString;
}

@end


@implementation BCCSQLModelObject

+ (BCCSQLEntity *)entity
{
    return nil;
}

+ (instancetype)modelObjectWithDictionary:(NSDictionary *)dictionary {
    return [[self alloc] initWithDictionary:dictionary];
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary
{
    self = [super init];
    if (!self) {
        return nil;
    }
    
    for (NSString *key in dictionary) {
        id value = [dictionary objectForKey:key];
        [self setValue:value forKey:key];
    }
    
    return self;
}

- (void)setValue:(id)value forKey:(NSString *)key
{
    if ([value isEqual:NSNull.null]) value = nil;
    
    __autoreleasing id validatedValue = value;
    
    if (![self validateChangeForPropertyKey:key value:&validatedValue]) {
        return;
    }
    
    [super setValue:validatedValue forKey:key];
    [self markPropertyKeyChanged:key];
}

// Adapted from MTLModel in Mantle, by Justin Spahr-Summers
- (BOOL)validateChangeForPropertyKey:(nonnull NSString *)key value:(inout id  *)value
{
    NSError *error;
    
    @try {
        if (![self validateValue:value forKey:key error:&error]) {
            return NO;
        }
    } @catch (NSException *ex) {
        NSLog(@"Exception setting key \"%@\" : %@", key, ex);
        
        // Fail fast in Debug builds.
#if DEBUG
        @throw ex;
#else
        return NO;
#endif
    }
    
    return YES;
}

- (id)valueForPropertyKey:(NSString *)key
{
    return [self valueForKey:key];
}

- (void)markPropertyKeyChanged:(NSString *)key
{
    if (!_changedKeys) {
        _changedKeys = [[NSMutableSet alloc] init];
    }
    
    [_changedKeys addObject:key];
}

- (NSSet <NSString *> *)changedPropertyKeys
{
    return _changedKeys;
}

- (void)resetChangedPropertyKeys
{
    _changedKeys = nil;
}

@end


@implementation BCCSQLTestModelObject

+ (void)performTest
{
    NSString *dbPath = [NSString stringWithFormat:@"%@/%@", [[NSFileManager defaultManager] BCC_cachePathIncludingAppName], @"test.sqlite"];
    BCCSQLContext *sqlContext = [[BCCSQLContext alloc] initWithDatabasePath:dbPath];
    
    [sqlContext registerEntity:[[self class] entity]];
    [sqlContext initializeDatabase];
    
    BCCSQLTestModelObject *foundObject = [sqlContext findObjectOfClass:[self class] primaryKeyValue:@(1)];
    
    NSLog(@"%@", foundObject);
    
    [foundObject setValue:@"Laurence Andersen" forKey:@"name"];
    
    NSLog(@"%@", foundObject);
    
    [sqlContext createOrUpdateModelObject:foundObject];
    
    //[sqlContext deleteObject:foundObject];
}

+ (BCCSQLEntity *)entity
{
    static BCCSQLEntity *entity;
    if (entity) {
        return entity;
    }
    
    entity = [[BCCSQLEntity alloc] initWithName:@"Record"];
    entity.tableName = @"records";
    entity.instanceClass = [self class];
    
    BCCSQLProperty *idProperty = [[BCCSQLProperty alloc] initWithColumnName:@"id"];
    idProperty.sqlType = BCCSQLTypeInteger;
    idProperty.propertyKey = NSStringFromSelector(@selector(objectID));
    
    [entity addProperty:idProperty];
    entity.primaryKey = idProperty.columnName;
    
    BCCSQLProperty *nameProperty = [[BCCSQLProperty alloc] initWithColumnName:@"name"];
    nameProperty.sqlType = BCCSQLTypeText;
    nameProperty.propertyKey = NSStringFromSelector(@selector(name));
    
    [entity addProperty:nameProperty];
    
    return entity;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%@: %p (objectID: %ld; name: %@)>", NSStringFromClass([self class]), self, (long)self.objectID, self.name];
}

@end
