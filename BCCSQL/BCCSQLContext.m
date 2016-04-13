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

@property (nonatomic, readonly) NSString *createTableSQL;

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

#pragma mark - CRUD

- (BOOL)modelObjectExistsForClass:(Class<BCCSQLModelObject>)modelObjectClass primaryKeyValue:(id)primaryKeyValue error:(NSError **)error
{
    if (!primaryKeyValue) {
        return NO;
    }
    
    BOOL objectExists = NO;
    
    __block BCCSQLEntity *entity = [modelObjectClass entity];
    if (!entity) {
        return NO;
    }
    
    NSString *tableName = entity.tableName;
    if (!tableName) {
        return NO;
    }
    
    BCCSQLProperty *primaryKeyProperty = entity.primaryKeyProperty;
    if (!primaryKeyProperty) {
        return NO;
    }
    
    NSString *primaryKeyColumnName = primaryKeyProperty.columnName;
    if (!primaryKeyColumnName) {
        return NO;
    }
    
    NSString *selectSQL = [NSString stringWithFormat:@"SELECT %@ FROM %@ WHERE %@ = ?", primaryKeyColumnName, tableName, primaryKeyColumnName];
    
    sqlite3_stmt *selectStatement = [self prepareSQLStatement:selectSQL withParameterValues:@[primaryKeyValue] error:error];
    if (*error != nil) {
        goto cleanup;
    }
    
    int sqlResult = sqlite3_step(selectStatement);
    if (sqlResult == SQLITE_ROW) {
        *error = nil;
        // TO DO: Return Error
        objectExists = YES;
    }
    
cleanup:
    sqlite3_finalize(selectStatement);
    return objectExists;
}

- (id <BCCSQLModelObject>)createOrUpdateModelObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass withDictionary:(NSDictionary <NSString *, id> *)dictionary primaryKeyValue:(id)primaryKeyValue
{
    __block BCCSQLEntity *entity = [modelObjectClass entity];
    if (!entity) {
        return nil;
    }
    
    NSString *tableName = entity.tableName;
    if (!tableName) {
        return nil;
    }
    
    BCCSQLProperty *primaryKeyProperty = entity.primaryKeyProperty;
    if (!primaryKeyProperty) {
        return nil;
    }
    
    NSString *primaryKeyColumnName = primaryKeyProperty.columnName;
    if (!primaryKeyColumnName) {
        return nil;
    }
    
    NSError *error;
    BOOL objectExists = [self modelObjectExistsForClass:modelObjectClass primaryKeyValue:primaryKeyValue error:&error];
    if (error) {
        return nil;
    }
    
    __block NSMutableString *columnsString = [[NSMutableString alloc] init];
    __block NSMutableString *valuesString = [[NSMutableString alloc] init];
    __block NSMutableArray *values = [[NSMutableArray alloc] init];
    __block BOOL atListStart = YES;
    
    [dictionary enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, id  _Nonnull obj, BOOL * _Nonnull stop) {
        if ([key isEqualToString:entity.primaryKey]) {
            return;
        }
        
        BCCSQLProperty *currentProperty = [entity propertyForKey:key];
        if (!currentProperty) {
            return;
        }
        
        NSString *columnName = currentProperty.columnName;
        if (!columnName) {
            return;
        }
        
        if (!atListStart) {
            [columnsString appendString:@", "];
        }
        
        if (objectExists) {
            [columnsString appendFormat:@"%@ = ?", columnName];
        } else {
            [columnsString appendString:columnName];
            
            if (!atListStart) {
                [valuesString appendString:@", "];
            }
            
            [valuesString appendString:@"?"];
        }
        
        [values addObject:obj];
        
        atListStart = NO;
    }];
    
    if (objectExists) {
        [values addObject:primaryKeyValue];
    }
        
    NSString *createOrUpdateSQL = objectExists ? [NSString stringWithFormat:@"UPDATE %@ SET %@ WHERE %@ = ?", tableName, columnsString, primaryKeyColumnName] : [NSString stringWithFormat:@"INSERT INTO %@ (%@) VALUES (%@)", tableName, columnsString, valuesString];
    
    sqlite3_stmt *createOrUpdateStatement = [self prepareSQLStatement:createOrUpdateSQL withParameterValues:values error:&error];
    if (error != nil) {
        goto cleanup;
    }
    
    int sqlResult = sqlite3_step(createOrUpdateStatement);
    if (sqlResult == SQLITE_ERROR) {
        goto cleanup;
    }
    
cleanup:
    if (error != nil) {
        NSLog(@"SQL Error: %@", error);
    }
    
    sqlite3_finalize(createOrUpdateStatement);
    
    // TO DO: Return updated object
    return nil;
}

- (void)createModelObjectOfClass:(Class<BCCSQLModelObject>)modelObjectClass withDictionary:(NSDictionary *)dictionary
{
    // TO DO
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
    
    NSString *tableName = entity.tableName;
    if (!tableName) {
        return nil;
    }
    
    BCCSQLProperty *primaryKeyProperty = entity.primaryKeyProperty;
    if (!primaryKeyProperty) {
        return nil;
    }
    
    NSString *primaryKeyColumnName = primaryKeyProperty.columnName;
    if (!primaryKeyColumnName) {
        return nil;
    }
    
    NSMutableString *columnsString = nil;

    NSArray<BCCSQLProperty *> *properties = entity.properties;
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


    NSString *selectSQL = [NSString stringWithFormat:@"SELECT %@ FROM %@ WHERE %@ = ?", columnsString ? columnsString : @"*", tableName, primaryKeyColumnName];
    
    id<BCCSQLModelObject> foundObject = nil;
    
    NSError *error;
    sqlite3_stmt *selectStatement = [self prepareSQLStatement:selectSQL withParameterValues:@[primaryKeyValue] error:&error];
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

- (__kindof NSArray<BCCSQLModelObject> *)findObjectsOfClass:(Class<BCCSQLModelObject>)modelObjectClass withPredicate:(NSPredicate *)predicate
{
    // TO DO
    return nil;
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
    
    NSString *tableName = entity.tableName;
    if (!tableName) {
        return;
    }
    
    BCCSQLProperty *primaryKeyProperty = entity.primaryKeyProperty;
    if (!primaryKeyProperty) {
        return;
    }
    
    NSString *primaryKeyColumnName = primaryKeyProperty.columnName;
    if (!primaryKeyColumnName) {
        return;
    }
    
    NSString *deleteSQL = [NSString stringWithFormat:@"DELETE FROM %@ WHERE %@ = ?", tableName, primaryKeyColumnName];
    
    NSError *error;
    sqlite3_stmt *deleteStatement = [self prepareSQLStatement:deleteSQL withParameterValues:@[primaryKeyValue] error:&error];
    if (error != nil) {
        goto cleanup;
    }
    
    int sqlResult = sqlite3_step(deleteStatement);
    if (sqlResult == SQLITE_ERROR) {
    
    }
    
cleanup:
    sqlite3_finalize(deleteStatement);
}

- (void)deleteObjectsOfClass:(Class<BCCSQLModelObject>)modelObjectClass withPredicate:(NSPredicate *)predicate
{
    // TO DO
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

- (BCCSQLProperty *)primaryKeyProperty
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

@end


@implementation BCCSQLTestModelObject

+ (void)performTest
{
    NSString *dbPath = [NSString stringWithFormat:@"%@/%@", [[NSFileManager defaultManager] BCC_cachePathIncludingAppName], @"test.sqlite"];
    BCCSQLContext *sqlContext = [[BCCSQLContext alloc] initWithDatabasePath:dbPath];
    
    [sqlContext registerEntity:[[self class] entity]];
    [sqlContext initializeDatabase];
    
    [sqlContext createOrUpdateModelObjectOfClass:[self class] withDictionary:@{NSStringFromSelector(@selector(name)): @"Buzz Andersen"} primaryKeyValue:@(0)];
    
    BCCSQLTestModelObject *foundObject = [sqlContext findObjectOfClass:[self class] primaryKeyValue:@(1)];
    
    NSLog(@"%@", foundObject);
    
    [sqlContext createOrUpdateModelObjectOfClass:[self class] withDictionary:@{NSStringFromSelector(@selector(name)): @"Laurence Andersen"} primaryKeyValue:@(1)];
    
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
