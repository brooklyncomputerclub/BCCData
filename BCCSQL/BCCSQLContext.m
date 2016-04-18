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

- (BOOL)modelObjectExistsForClass:(Class<BCCSQLModelObject>)modelObjectClass primaryKeyValue:(id)primaryKeyValue error:(NSError **)error;

- (sqlite3_stmt *)prepareSQLStatement:(NSString *)SQLString withParameterValues:(NSArray *)parameterValues error:(NSError **)error;
- (id<BCCSQLModelObject>)nextObjectFromStatement:(sqlite3_stmt *)statement forEntity:(BCCSQLEntity *)entity error:(NSError **)error;

@end


@interface BCCSQLEntity ()

@property (strong, nonatomic) NSMutableArray<BCCSQLProperty *> *properties;

@property (strong, nonatomic) NSString *primaryKeyPropertyKey;

@property (nonatomic, readonly) NSString *createTableSQL;
@property (nonatomic, readonly) NSString *deleteSQL;
@property (nonatomic, readonly) NSString *findByPrimaryKeySQL;

- (NSString *)insertSQLForPropertyDictionary:(NSDictionary *)dictionary values:(NSArray **)values;
- (NSString *)updateSQLForPropertyDictionary:(NSDictionary <NSString *, id> *)dictionary values:(NSArray **)values;

@end


@interface BCCSQLProperty ()

@property (nonatomic, readonly) NSString *columnDefinitionSQL;

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

- (void)dealloc
{
    sqlite3_close_v2(_databaseConnection);
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

#pragma mark - Object Create/Update

- (id<BCCSQLModelObject>)createModelObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass withDictionary:(NSDictionary *)dictionary
{
    if (!modelObjectClass) {
        return nil;
    }
    
    BCCSQLEntity *entity = [modelObjectClass entity];
    if (!entity) {
        return nil;
    }
    
    NSArray *values;
    NSString *insertSQL = [entity insertSQLForPropertyDictionary:dictionary values:&values];
    if (!insertSQL) {
        return nil;
    }
    
    NSError *error;
    sqlite3_stmt *insertStatement = [self prepareSQLStatement:insertSQL withParameterValues:values error:&error];
    if (error != nil) {
        goto cleanup;
    }
    
    int sqlResult = sqlite3_step(insertStatement);
    if (sqlResult == SQLITE_ERROR) {
        goto cleanup;
    }
    
cleanup:
    if (error != nil) {
        NSLog(@"SQL Error: %@", error);
    }
    
    sqlite3_finalize(insertStatement);
    
    // TO DO: Return updated object
    return nil;
}

- (id<BCCSQLModelObject>)updateModelObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass withDictionary:(NSDictionary *)dictionary
{
    if (!modelObjectClass) {
        return nil;
    }
    
    BCCSQLEntity *entity = [modelObjectClass entity];
    if (!entity) {
        return nil;
    }
    
    NSArray *values;
    NSString *updateSQL = [entity updateSQLForPropertyDictionary:dictionary values:&values];
    if (!updateSQL) {
        return nil;
    }
    
    NSError *error;
    sqlite3_stmt *updateStatement = [self prepareSQLStatement:updateSQL withParameterValues:values error:&error];
    if (error != nil) {
        goto cleanup;
    }
    
    int sqlResult = sqlite3_step(updateStatement);
    if (sqlResult == SQLITE_ERROR) {
        goto cleanup;
    }
    
cleanup:
    if (error != nil) {
        NSLog(@"SQL Error: %@", error);
    }
    
    sqlite3_finalize(updateStatement);
    
    // TO DO: Return updated object
    return nil;
}

- (id <BCCSQLModelObject>)createOrUpdateModelObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass withDictionary:(NSDictionary <NSString *, id> *)dictionary
{
    BCCSQLEntity *entity = [modelObjectClass entity];
    if (!entity) {
        return nil;
    }
    
    NSString *primaryKeyPropertyKey = entity.primaryKeyProperty.propertyKey;
    if (!primaryKeyPropertyKey) {
        return nil;
    }
    
    BOOL createObject = YES;
    
    id primaryKeyValue = [dictionary valueForKey:primaryKeyPropertyKey];
    if (primaryKeyValue) {
        NSError *error;
        createObject = ([self modelObjectExistsForClass:modelObjectClass primaryKeyValue:primaryKeyValue error:&error] == NO);
        if (error) {
            return nil;
        }
    }
    
    return createObject ? [self createModelObjectOfClass:modelObjectClass withDictionary:dictionary] : [self updateModelObjectOfClass:modelObjectClass withDictionary:dictionary];
}

#pragma mark - Object Delete

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
    
    NSString *primaryKeyPropertyPath = entity.primaryKeyProperty.propertyKey;
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
    
    NSString *deleteSQL = entity.deleteSQL;
    
    NSError *error;
    sqlite3_stmt *deleteStatement = [self prepareSQLStatement:deleteSQL withParameterValues:@[primaryKeyValue] error:&error];
    if (error != nil) {
        goto cleanup;
    }
    
    int sqlResult = sqlite3_step(deleteStatement);
    if (sqlResult == SQLITE_ERROR) {
        // TO DO: Return Error
    }
    
cleanup:
    sqlite3_finalize(deleteStatement);
}

- (void)deleteObjectsOfClass:(Class<BCCSQLModelObject>)modelObjectClass withPredicate:(NSPredicate *)predicate
{
    // TO DO
}


#pragma mark - Object Find

- (BOOL)modelObjectExistsForClass:(Class<BCCSQLModelObject>)modelObjectClass primaryKeyValue:(id)primaryKeyValue error:(NSError **)error
{
    if (!primaryKeyValue) {
        return NO;
    }
    
    __block BCCSQLEntity *entity = [modelObjectClass entity];
    if (!entity) {
        return NO;
    }
    
    NSString *findSQL = entity.findByPrimaryKeySQL;
    if (!findSQL) {
        return NO;
    }
    
    BOOL objectExists = NO;
    
    sqlite3_stmt *findStatement = [self prepareSQLStatement:findSQL withParameterValues:@[primaryKeyValue] error:error];
    if (*error != nil) {
        goto cleanup;
    }
    
    int sqlResult = sqlite3_step(findStatement);
    if (sqlResult == SQLITE_ROW) {
        *error = nil;
        // TO DO: Return Error
        objectExists = YES;
    }
    
cleanup:
    sqlite3_finalize(findStatement);
    return objectExists;
}

- (id<BCCSQLModelObject>)findModelObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass primaryKeyValue:(id)primaryKeyValue
{
    if (!modelObjectClass) {
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
    
    NSString *findSQL = entity.findByPrimaryKeySQL;
    if (!findSQL) {
        return nil;
    }
    
    id<BCCSQLModelObject> foundObject = nil;
    
    NSError *error;
    sqlite3_stmt *selectStatement = [self prepareSQLStatement:findSQL withParameterValues:@[primaryKeyValue] error:&error];
    if (error != nil) {
        goto cleanup;
    }
    
    foundObject = [self nextObjectFromStatement:selectStatement forEntity:entity error:&error];
    
cleanup:
    if (error != nil) {
        NSLog(@"SQL Error: %@", error);
    }
    
    return foundObject;
}

- (__kindof NSArray<BCCSQLModelObject> *)findModelObjectsOfClass:(Class<BCCSQLModelObject>)modelObjectClass withPredicate:(NSPredicate *)predicate
{
    // TO DO
    return nil;
}

#pragma mark - Prepared Statements

- (sqlite3_stmt *)prepareSQLStatement:(NSString *)SQLString withParameterValues:(NSArray *)parameterValues error:(NSError **)error
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
    
    [parameterValues enumerateObjectsUsingBlock:^(id  _Nonnull currentParameterValue, NSUInteger idx, BOOL * _Nonnull stop) {
        int currentIndex = (int)idx + 1;
        
        if ([currentParameterValue isKindOfClass:[NSString class]]) {
            sqlite3_bind_text(statement, currentIndex, [(NSString *)currentParameterValue UTF8String], -1, SQLITE_TRANSIENT);
        } else if ([currentParameterValue isKindOfClass:[NSNumber class]]) {
            sqlite3_bind_int(statement, currentIndex, [(NSNumber *)currentParameterValue intValue]);
        }
    }];
    
    *error = nil;
    return statement;
}

- (id<BCCSQLModelObject>)nextObjectFromStatement:(sqlite3_stmt *)statement forEntity:(BCCSQLEntity *)entity error:(NSError **)error
{
    if (!_databaseConnection || !statement || !entity) {
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
    
    NSArray <BCCSQLProperty *> *properties = self.properties;
    
    NSInteger columnCount = properties.count;
    if (columnCount > 0) {
        [columnsString appendString:@"("];
    }
    
    __block BOOL hadValidColumns = NO;
    
    [properties enumerateObjectsUsingBlock:^(BCCSQLProperty * _Nonnull currentProperty, NSUInteger idx, BOOL * _Nonnull stop) {
        NSString *propertyKey = currentProperty.propertyKey;
        if (!propertyKey) {
            return;
        }
        
        NSString *columnDefinitionSQL = currentProperty.columnDefinitionSQL;
        if (!columnDefinitionSQL) {
            return;
        }
        
        hadValidColumns = YES;
        [columnsString appendString:columnDefinitionSQL];
        
        if ([currentProperty.propertyKey isEqualToString:self.primaryKeyPropertyKey]) {
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

- (NSString *)deleteSQL
{
    NSString *tableName = self.tableName;
    if (!tableName) {
        return nil;
    }
    
    NSString *primaryKeyColumnName = self.primaryKeyProperty.columnName;
    if (!primaryKeyColumnName) {
        return nil;
    }
    
    NSString *deleteSQL = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ = ?", tableName, primaryKeyColumnName];

    return deleteSQL;
}

- (NSString *)findByPrimaryKeySQL
{
    NSString *tableName = self.tableName;
    if (!tableName) {
        return nil;
    }
    
    NSString *primaryKeyColumnName = self.primaryKeyProperty.columnName;
    if (!primaryKeyColumnName) {
        return nil;
    }
    
    NSMutableString *columnsString = nil;
    
    NSArray<BCCSQLProperty *> *properties = self.properties;
    if (properties.count > 0) {
        columnsString = [[NSMutableString alloc] init];
        
        [properties enumerateObjectsUsingBlock:^(BCCSQLProperty * _Nonnull currentProperty, NSUInteger idx, BOOL * _Nonnull stop) {
            NSString *columnName = currentProperty.columnName;
            if (!columnName) {
                return;
            }
            
            if (idx > 0) {
                [columnsString appendString:@" ,"];
            }
            
            [columnsString appendString:columnName];
        }];
    }
    
    NSString *findSQL = [NSString stringWithFormat:@"SELECT %@ FROM %@ WHERE %@ = ?", columnsString, tableName, primaryKeyColumnName];

    return findSQL;
}

- (NSString *)insertSQLForPropertyDictionary:(NSDictionary <NSString *, id> *)dictionary values:(NSArray **)values
{
    NSString *tableName = self.tableName;
    if (!tableName) {
        return nil;
    }
    
    BCCSQLProperty *primaryKeyProperty = self.primaryKeyProperty;
    if (!primaryKeyProperty) {
        return nil;
    }
    
    NSString *primaryKeyColumnName = primaryKeyProperty.columnName;
    if (!primaryKeyColumnName) {
        return nil;
    }
    
    __block NSMutableString *columnsString = [[NSMutableString alloc] init];
    __block NSMutableString *valuesString = [[NSMutableString alloc] init];
    __block NSMutableArray *valueList = [[NSMutableArray alloc] init];
    
    NSArray <NSString *> *propertyKeysToWrite = dictionary.allKeys;
    
    [propertyKeysToWrite enumerateObjectsUsingBlock:^(NSString * _Nonnull currentPropertyKey, NSUInteger idx, BOOL * _Nonnull stop) {
        BCCSQLProperty *currentProperty = [self propertyForKey:currentPropertyKey];
        if (!currentProperty) {
            return;
        }
        
        NSString *columnName = currentProperty.columnName;
        if (!columnName) {
            return;
        }
        
        if (idx > 0) {
            [columnsString appendString:@", "];
            [valuesString appendString:@", "];
        }
        
        [columnsString appendString:columnName];
        [valuesString appendString:@"?"];
        
        id currentValue = [dictionary valueForKey:currentPropertyKey];
        [valueList addObject:currentValue];
    }];
    
    NSString *insertSQL = [NSString stringWithFormat:@"INSERT INTO %@ (%@) VALUES (%@)", tableName, columnsString, valuesString];
    *values = valueList;
    
    return insertSQL;
}

- (NSString *)updateSQLForPropertyDictionary:(NSDictionary <NSString *, id> *)dictionary values:(NSArray **)values
{
    // Must include primary key and at least one column value
    // for updates
    if (dictionary.count < 2) {
        return nil;
    }
    
    NSString *tableName = self.tableName;
    if (!tableName) {
        return nil;
    }
    
    BCCSQLProperty *primaryKeyProperty = self.primaryKeyProperty;
    if (!primaryKeyProperty) {
        return nil;
    }
    
    NSString *primaryKeyColumnName = primaryKeyProperty.columnName;
    if (!primaryKeyColumnName) {
        return nil;
    }
    
    NSString *primaryKeyPropertyKey = primaryKeyProperty.propertyKey;
    if (!primaryKeyPropertyKey) {
        return nil;
    }
    
    id primaryKeyValue = [dictionary valueForKey:primaryKeyPropertyKey];
    if (!primaryKeyValue) {
        return nil;
    }
    
    __block NSMutableString *columnsString = [[NSMutableString alloc] init];
    __block NSMutableArray *valueList = [[NSMutableArray alloc] init];
    
    NSArray <NSString *> *propertyKeysToWrite = dictionary.allKeys;
    
    [propertyKeysToWrite enumerateObjectsUsingBlock:^(NSString * _Nonnull currentPropertyKey, NSUInteger idx, BOOL * _Nonnull stop) {
        // Don't update primary keys
        if ([currentPropertyKey isEqualToString:primaryKeyProperty.propertyKey]) {
            return;
        }
        
        BCCSQLProperty *currentProperty = [self propertyForKey:currentPropertyKey];
        if (!currentProperty) {
            return;
        }
        
        NSString *columnName = currentProperty.columnName;
        if (!columnName) {
            return;
        }
        
        if (idx > 0) {
            [columnsString appendString:@", "];
        }
        
        [columnsString appendFormat:@"%@ = ?", columnName];
        
        id currentValue = [dictionary valueForKey:currentPropertyKey];
        [valueList addObject:currentValue];
    }];
    
    [valueList addObject:primaryKeyValue];

    NSString *updateSQL = [NSString stringWithFormat:@"UPDATE %@ SET %@ WHERE %@ = ?", tableName, columnsString, primaryKeyColumnName];
    *values = valueList;
    
    return updateSQL;
}

- (BCCSQLProperty *)primaryKeyProperty
{
    if (!self.primaryKeyPropertyKey) {
        return nil;
    }
    
    return [self propertyForKey:self.primaryKeyPropertyKey];
}

- (void)addProperty:(BCCSQLProperty *)property
{
    [self addProperty:property primaryKey:NO];
}

- (void)addProperty:(BCCSQLProperty *)property primaryKey:(BOOL)isPrimaryKey
{
    if (!property) {
        return;
    }
    
    if (!_properties) {
        _properties = [[NSMutableArray alloc] init];
    }
    
    [_properties addObject:property];
    
    if (isPrimaryKey) {
        _primaryKeyPropertyKey = property.propertyKey;
    }
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

@end


@implementation BCCSQLTestModelObject

+ (void)performTest
{
    NSString *dbPath = [NSString stringWithFormat:@"%@/%@", [[NSFileManager defaultManager] BCC_cachePathIncludingAppName], @"test.sqlite"];
    BCCSQLContext *sqlContext = [[BCCSQLContext alloc] initWithDatabasePath:dbPath];

    BCCSQLEntity *entity = [[self class] entity];
    
    [sqlContext registerEntity:entity];
    [sqlContext initializeDatabase];
    
    [sqlContext createOrUpdateModelObjectOfClass:[self class] withDictionary:@{NSStringFromSelector(@selector(name)): @"Buzz Andersen"}];
    
    BCCSQLTestModelObject *foundObject = [sqlContext findModelObjectOfClass:[self class] primaryKeyValue:@(1)];
    
    NSLog(@"%@", foundObject);
    
    [sqlContext createOrUpdateModelObjectOfClass:[self class] withDictionary:@{entity.primaryKeyProperty.propertyKey: @(1),  NSStringFromSelector(@selector(name)): @"Laurence Andersen"}];
    
    [sqlContext deleteObject:foundObject];
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
    
    [entity addProperty:idProperty primaryKey:YES];
    
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
